import FieldnoteKit
import Foundation
import OSLog
import SwiftData

/// Every read and write of meeting data goes through here.
@ModelActor
public actor MeetingStore {

    private var log: Logger { Logger(subsystem: "com.publicarray.fieldnotes", category: "store") }

    // MARK: - Container

    @MainActor
    public static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, Segment.self, Speaker.self, SummaryRecord.self, Folder.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            // No CloudKit. There is no sync, no account and no server (constraint 3).
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Recording lifecycle

    @discardableResult
    public func createMeeting(
        title: String,
        type: MeetingType,
        locale: Locale,
        consentAcknowledged: Bool,
        latitude: Double? = nil,
        longitude: Double? = nil,
        startedAt: Date = Date()
    ) throws -> UUID {
        let meeting = Meeting(
            title: title,
            type: type,
            startedAt: startedAt,
            locale: locale,
            latitude: latitude,
            longitude: longitude
        )
        meeting.consentAcknowledged = consentAcknowledged
        modelContext.insert(meeting)
        try modelContext.save()
        return meeting.id
    }

    /// Called on stop. Persists what the recorder produced and queues the meeting for
    /// the pipeline. Fast by design: the long work belongs to the background task.
    public func finishRecording(_ result: RecordingResult) throws {
        guard let meeting = try meeting(with: result.meetingID) else { return }
        meeting.duration = result.duration
        meeting.processingState = .queued
        replaceSegments(result.liveSegments, on: meeting)
        rebuildSearchText(for: meeting)
        try modelContext.save()
    }

    public func markStage(_ stage: ProcessingStage, meetingID: UUID, estimatedCompletion: Date?) async {
        guard let meeting = try? meeting(with: meetingID), !isStoppedByUser(meeting) else { return }
        meeting.processingState = ProcessingState(stage: stage)
        meeting.estimatedCompletion = estimatedCompletion
        meeting.failureMessage = nil
        try? modelContext.save()
    }

    /// The user stopped processing. Not `queued`, so nothing picks it up again until
    /// they tap Try again; the checkpoint keeps what already finished.
    public func markStopped(meetingID: UUID) {
        guard let meeting = try? meeting(with: meetingID), !meeting.processingState.isTerminal else { return }
        meeting.processingState = .failed
        meeting.failureMessage = Self.stoppedMessage
        meeting.estimatedCompletion = nil
        try? modelContext.save()
    }

    public static let stoppedMessage = "Stopped by you. Tap Try again to carry on from where it stopped."

    /// A run being cancelled can still report a stage on its way out; that mustn't
    /// undo the user's stop.
    private func isStoppedByUser(_ meeting: Meeting) -> Bool {
        meeting.processingState == .failed && meeting.failureMessage == Self.stoppedMessage
    }

    /// Puts a stopped or failed meeting back in the queue; it resumes from its last
    /// finished stage.
    public func requeue(meetingID: UUID) {
        guard let meeting = try? meeting(with: meetingID), meeting.processingState == .failed else { return }
        meeting.processingState = .queued
        meeting.failureMessage = nil
        try? modelContext.save()
    }

    public func markWaiting(meetingID: UUID, message: String) async {
        guard let meeting = try? meeting(with: meetingID), !isStoppedByUser(meeting) else { return }
        meeting.processingState = .queued
        meeting.failureMessage = message
        meeting.estimatedCompletion = nil
        try? modelContext.save()
    }

    public func markFailed(meetingID: UUID, message: String) async {
        guard let meeting = try? meeting(with: meetingID) else { return }
        meeting.processingState = .failed
        meeting.failureMessage = message
        meeting.estimatedCompletion = nil
        try? modelContext.save()
    }

    /// The transcript and speakers, saved as soon as those stages finish, so the
    /// meeting shows them while the summary is still being written, or after the user
    /// stops it. `apply` writes them again with the summary's speaker names.
    public func applyTranscript(_ segments: [TranscriptSegment], embeddings: [String: [Float]], replacesEditedSegments: Bool, to meetingID: UUID) async {
        guard let meeting = try? meeting(with: meetingID) else { return }
        replaceTranscript(segments, embeddings: embeddings, speakerNames: [:], keepEdits: !replacesEditedSegments, on: meeting)
        rebuildSearchText(for: meeting)
        try? modelContext.save()
    }

    public func apply(_ output: ProcessingPipeline.Output, to meetingID: UUID) async {
        guard let meeting = try? meeting(with: meetingID) else { return }

        replaceTranscript(
            output.segments,
            embeddings: output.embeddings,
            speakerNames: output.summary.speakerNames,
            keepEdits: !output.replacesEditedSegments,
            on: meeting
        )

        if let existing = meeting.summary {
            modelContext.delete(existing)
        }
        let record = SummaryRecord(summary: output.summary)
        record.meeting = meeting
        modelContext.insert(record)

        meeting.processingState = .complete
        meeting.failureMessage = nil
        meeting.estimatedCompletion = nil
        rebuildSearchText(for: meeting)
        try? modelContext.save()

        // The checkpoints have done their job once the results are in the database.
        if let store = try? ProcessingCheckpointStore(meetingID: meetingID) {
            await store.clear()
        }
    }

    // MARK: - Pipeline input

    public func pendingJobs() async -> [ProcessingPipeline.Input] {
        let terminal = [ProcessingState.complete.rawValue, ProcessingState.failed.rawValue, ProcessingState.recording.rawValue]
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { !terminal.contains($0.processingStateRaw) },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        let meetings = (try? modelContext.fetch(descriptor)) ?? []
        return meetings.map { meeting in
            ProcessingPipeline.Input(
                meetingID: meeting.id,
                title: meeting.title,
                date: meeting.startedAt,
                locale: meeting.locale,
                chunks: ChunkedAudioWriter.existingChunks(
                    in: FieldnoteStorage.audioChunkDirectory(for: meeting.id)
                ),
                liveSegments: meeting.orderedSegments.map(\.value),
                duration: meeting.duration
            )
        }
    }

    // MARK: - Editing

    public func setPlaceName(_ name: String?, for meetingID: UUID) throws {
        guard let meeting = try meeting(with: meetingID) else { return }
        meeting.placeName = name
        rebuildSearchText(for: meeting)
        try modelContext.save()
    }

    /// Meetings with coordinates but no place name yet: recorded before place names
    /// existed, or before the lookup finished.
    public func meetingsNeedingPlaceNames() throws -> [(id: UUID, latitude: Double, longitude: Double)] {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.latitude != nil && $0.placeName == nil })
        return try modelContext.fetch(descriptor).compactMap { meeting in
            guard let latitude = meeting.latitude, let longitude = meeting.longitude else { return nil }
            return (meeting.id, latitude, longitude)
        }
    }

    public func renameMeeting(_ meetingID: UUID, to title: String) throws {
        let trimmed = title.trimmed()
        guard !trimmed.isEmpty, let meeting = try meeting(with: meetingID) else { return }
        meeting.title = trimmed
        rebuildSearchText(for: meeting)
        try modelContext.save()
    }

    /// What "Redo" in debug mode re-runs. Each one re-runs that stage and every
    /// stage after it.
    public enum RedoStage: String, Sendable {
        case transcript, speakers, summary
    }

    /// Queues a finished meeting to run again from `stage`, by writing a checkpoint
    /// that marks the earlier stages done with the meeting's current results. The
    /// caller then submits the background task. Current results stay in place
    /// until the new ones replace them, so a failed redo loses nothing.
    public func prepareRedo(_ stage: RedoStage, meetingID: UUID) async throws {
        guard let meeting = try meeting(with: meetingID), meeting.processingState.isTerminal else { return }
        let segments = meeting.orderedSegments.map(\.value)

        let checkpoints = try ProcessingCheckpointStore(meetingID: meetingID)
        await checkpoints.clear()
        let fresh = try ProcessingCheckpointStore(meetingID: meetingID)
        var checkpoint = ProcessingCheckpoint(meetingID: meetingID)

        switch stage {
        case .transcript:
            checkpoint.redoTranscript = true
        case .speakers:
            try await fresh.saveSegments(segments)
            checkpoint.completedStages = [.transcribing]
        case .summary:
            try await fresh.saveSegments(segments)
            // No new spans: alignment leaves the current speaker labels as they are.
            let embeddings = Dictionary(
                meeting.speakers.compactMap { speaker -> (String, [Float])? in
                    guard let data = speaker.embedding else { return nil }
                    return (speaker.label, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
                },
                uniquingKeysWith: { first, _ in first }
            )
            try await fresh.saveSpans([], embeddings: embeddings)
            checkpoint.completedStages = [.transcribing, .diarizing]
        }
        try await fresh.save(checkpoint)

        meeting.processingState = .queued
        meeting.failureMessage = nil
        try modelContext.save()
        DebugLog.shared.log("store", "\(DebugLog.short(meetingID)): queued to redo \(stage.rawValue)")
    }

    /// Manual transcript edit. Marks the segment so re-running diarization does not
    /// undo it.
    public func updateSegmentText(_ segmentID: UUID, to text: String) throws {
        guard let segment = try segment(with: segmentID) else { return }
        segment.text = text
        segment.editedByUser = true
        // The timings were for the old words.
        segment.wordsData = nil
        if let meeting = segment.meeting { rebuildSearchText(for: meeting) }
        try modelContext.save()
    }

    /// Relabels one line without disturbing its neighbours (spec 9).
    public func relabelSegment(_ segmentID: UUID, to speakerID: String?) throws {
        guard let segment = try segment(with: segmentID) else { return }
        segment.speakerID = speakerID
        segment.editedByUser = true
        try modelContext.save()
    }

    /// Renames a speaker within this meeting only.
    public func renameSpeaker(_ speakerID: UUID, to displayName: String?) throws {
        let descriptor = FetchDescriptor<Speaker>(predicate: #Predicate { $0.id == speakerID })
        guard let speaker = try modelContext.fetch(descriptor).first else { return }
        speaker.displayName = displayName?.trimmed().nilIfEmpty
        if let meeting = speaker.meeting { rebuildSearchText(for: meeting) }
        try modelContext.save()
    }

    public func setFolder(_ folderID: UUID?, for meetingID: UUID) throws {
        guard let meeting = try meeting(with: meetingID) else { return }
        if let folderID {
            let descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderID })
            meeting.folder = try modelContext.fetch(descriptor).first
        } else {
            meeting.folder = nil
        }
        try modelContext.save()
    }

    public func delete(meetingID: UUID) throws {
        guard let meeting = try meeting(with: meetingID) else { return }
        modelContext.delete(meeting)
        try modelContext.save()
        // Audio and checkpoints are outside the database; delete means delete.
        try? FileManager.default.removeItem(at: FieldnoteStorage.meetingDirectory(for: meetingID))
    }

    // MARK: - Reading

    public func meetingSnapshot(_ meetingID: UUID) throws -> MeetingSnapshot? {
        guard let meeting = try meeting(with: meetingID) else { return nil }
        return MeetingSnapshot(meeting: meeting)
    }

    public func search(_ query: String, limit: Int = 50) throws -> [MeetingSnapshot] {
        // Every word, in any order. The longest word goes to the database; the
        // rest are checked here (a #Predicate can't take a variable number of terms).
        let terms = MeetingSearch.terms(query)
        guard let needle = terms.first else { return try recentSnapshots(limit: limit) }
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.searchText.contains(needle) },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
            .filter { MeetingSearch.matches($0.searchText, terms: terms) }
            .prefix(limit)
            .map(MeetingSnapshot.init)
    }

    public func recentSnapshots(limit: Int = 50) throws -> [MeetingSnapshot] {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(MeetingSnapshot.init)
    }

    // MARK: - Plumbing

    private func meeting(with id: UUID) throws -> Meeting? {
        try modelContext.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
    }

    private func segment(with id: UUID) throws -> Segment? {
        try modelContext.fetch(FetchDescriptor<Segment>(predicate: #Predicate { $0.id == id })).first
    }

    private func replaceTranscript(
        _ segments: [TranscriptSegment],
        embeddings: [String: [Float]],
        speakerNames: [String: String],
        keepEdits: Bool,
        on meeting: Meeting
    ) {
        replaceSegments(segments, on: meeting, keepEdits: keepEdits)

        // Speakers are per-meeting labels. The embeddings ride along for v2. A name
        // the user gave a speaker survives re-processing; the summary's grounded
        // names only fill labels that have none.
        let existingNames = Dictionary(
            meeting.speakers.compactMap { speaker in speaker.displayName.map { (speaker.label, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        meeting.speakers.forEach(modelContext.delete)
        meeting.speakers = []
        let labels = Set(segments.compactMap(\.speakerID)).sorted()
        for label in labels {
            // Grounded in something a participant actually said (SummaryGrounder) --
            // never a guess. A user's own rename always wins over this because it can
            // only ever start unset: it is applied at the same point everything else
            // about this speaker is (re)created from scratch.
            let speaker = Speaker(
                label: label,
                displayName: existingNames[label] ?? speakerNames[label],
                embedding: embeddings[label]
            )
            speaker.meeting = meeting
            modelContext.insert(speaker)
        }
    }

    private func replaceSegments(_ segments: [TranscriptSegment], on meeting: Meeting, keepEdits: Bool = true) {
        // Manual edits win over anything the pipeline produces, unless the transcript
        // itself is being redone.
        let edited = keepEdits ? meeting.segments.filter(\.editedByUser) : []
        let editedIDs = Set(edited.map(\.id))
        meeting.segments.filter { !editedIDs.contains($0.id) }.forEach(modelContext.delete)

        var kept = edited
        for value in segments where !editedIDs.contains(value.id) {
            let segment = Segment(value: value)
            segment.meeting = meeting
            modelContext.insert(segment)
            kept.append(segment)
        }
        meeting.segments = kept
    }

    private func rebuildSearchText(for meeting: Meeting) {
        meeting.searchText = MeetingSearch.indexText(
            title: meeting.title,
            placeName: meeting.placeName,
            speakerNames: meeting.speakers.compactMap(\.displayName),
            segments: meeting.orderedSegments.map(\.text),
            summary: meeting.summary?.summary
        )
    }

    /// Re-indexes every meeting once when what's indexed changes
    /// (`MeetingSearch.indexVersion`), so older meetings are found by the same rules.
    public func reindexIfNeeded() {
        let key = "searchIndexVersion"
        guard UserDefaults.standard.integer(forKey: key) < MeetingSearch.indexVersion else { return }
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        meetings.forEach(rebuildSearchText)
        try? modelContext.save()
        UserDefaults.standard.set(MeetingSearch.indexVersion, forKey: key)
        DebugLog.shared.log("store", "re-indexed \(meetings.count) meeting(s) for search")
    }
}

extension MeetingStore: ProcessingJobProvider {}
