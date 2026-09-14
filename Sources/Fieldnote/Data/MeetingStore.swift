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
        longitude: Double? = nil
    ) throws -> UUID {
        let meeting = Meeting(title: title, type: type, locale: locale, latitude: latitude, longitude: longitude)
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

    public func markStage(_ stage: ProcessingStage, meetingID: UUID) async {
        guard let meeting = try? meeting(with: meetingID) else { return }
        meeting.processingState = ProcessingState(stage: stage)
        try? modelContext.save()
    }

    public func markFailed(meetingID: UUID, message: String) async {
        guard let meeting = try? meeting(with: meetingID) else { return }
        meeting.processingState = .failed
        meeting.failureMessage = message
        try? modelContext.save()
    }

    public func apply(_ output: ProcessingPipeline.Output, to meetingID: UUID) async {
        guard let meeting = try? meeting(with: meetingID) else { return }

        replaceSegments(output.segments, on: meeting)

        // Speakers are per-meeting labels. The embeddings ride along for v2.
        meeting.speakers.forEach(modelContext.delete)
        meeting.speakers = []
        let labels = Set(output.segments.compactMap(\.speakerID)).sorted()
        for label in labels {
            // Grounded in something a participant actually said (SummaryGrounder) --
            // never a guess. A user's own rename always wins over this because it can
            // only ever start unset: it is applied at the same point everything else
            // about this speaker is (re)created from scratch.
            let speaker = Speaker(
                label: label,
                displayName: output.summary.speakerNames[label],
                embedding: output.embeddings[label]
            )
            speaker.meeting = meeting
            modelContext.insert(speaker)
        }

        if let existing = meeting.summary {
            modelContext.delete(existing)
        }
        let record = SummaryRecord(summary: output.summary)
        record.meeting = meeting
        modelContext.insert(record)

        meeting.processingState = .complete
        meeting.failureMessage = nil
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
                type: meeting.type,
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

    /// Manual transcript edit. Marks the segment so re-running diarization does not
    /// undo it.
    public func updateSegmentText(_ segmentID: UUID, to text: String) throws {
        guard let segment = try segment(with: segmentID) else { return }
        segment.text = text
        segment.editedByUser = true
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
        let needle = query.lowercased().trimmed()
        guard !needle.isEmpty else { return try recentSnapshots(limit: limit) }
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.searchText.contains(needle) },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(MeetingSnapshot.init)
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

    private func replaceSegments(_ segments: [TranscriptSegment], on meeting: Meeting) {
        // Manual edits win over anything the pipeline produces.
        let edited = meeting.segments.filter(\.editedByUser)
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
        var parts = [meeting.title]
        parts.append(contentsOf: meeting.segments.map(\.text))
        if let summary = meeting.summary?.summary {
            parts.append(summary.overview)
            parts.append(contentsOf: summary.decisions.map(\.statement))
            parts.append(contentsOf: summary.actionItems.map(\.task))
        }
        meeting.searchText = parts.joined(separator: " ").lowercased()
    }
}

extension MeetingStore: ProcessingJobProvider {}
