import FieldnoteKit
import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let meetingID: UUID

    @State private var meeting: MeetingSnapshot?
    @State private var tab: Tab = .summary
    @State private var editingSegment: TranscriptSegment?
    @State private var relabelling: TranscriptSegment?
    @State private var scrollTarget: UUID?
    @State private var composing = false
    @State private var share = SharePresentation()
    @State private var renaming = false
    @State private var newTitle = ""
    /// The speaker label being renamed, e.g. "S1".
    @State private var renamingSpeaker: String?
    @State private var newSpeakerName = ""
    /// Asked first when a transcript redo would replace the user's edits.
    @State private var confirmingRedoTranscript = false
    /// Bumped to restart polling after a redo is queued.
    @State private var pollGeneration = 0
    @State private var player = MeetingPlayer()
    /// Keep the playing line in view. Off when the user wants to read elsewhere.
    @State private var follow = true
    /// Find in this meeting; starts with the list's search, if there was one.
    @State private var find = ""
    @State private var findPrefilled = false

    enum Tab: String, CaseIterable { case summary, transcript }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                ProgressView()
            }
        }
        .task(id: pollGeneration) { await loadAndPollWhileProcessing() }
        .task { await player.load(meetingID: meetingID) }
        .onDisappear { player.stop() }
        .navigationTitle(meeting?.title ?? "Meeting")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $find, prompt: "Find in this meeting")
        .onAppear {
            guard !findPrefilled else { return }
            findPrefilled = true
            if !model.searchQuery.trimmed().isEmpty { find = model.searchQuery }
        }
        // Show the transcript only when it has a matching line: a list search can
        // match the title or the notes alone.
        .onChange(of: find) { showTranscriptIfFound() }
        .onChange(of: meeting?.id) { showTranscriptIfFound() }
        .toolbar {
            if let meeting {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        SharePayloadMenu(meeting: meeting) { payload, format in
                            share.select(meeting: meeting, payload: payload, format: format)
                        }
                        Divider()
                        Button("Share meeting…", systemImage: "square.and.arrow.up.on.square") {
                            composing = true
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Rename", systemImage: "pencil") {
                        newTitle = meeting.title
                        renaming = true
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button("Redo transcript", systemImage: "waveform") {
                            if meeting.segments.contains(where: \.editedByUser) {
                                confirmingRedoTranscript = true
                            } else {
                                redo(.transcript, meeting)
                            }
                        }
                        Button("Redo speakers", systemImage: "person.2") { redo(.speakers, meeting) }
                        Button("Redo summary", systemImage: "text.badge.star") { redo(.summary, meeting) }
                    } label: {
                        Label("Redo", systemImage: "arrow.clockwise")
                    }
                    .disabled(!meeting.state.isTerminal)
                }
            }
        }
        .alert("Rename meeting", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    await model.renameMeeting(meetingID, to: newTitle)
                    await load()
                }
            }
            .disabled(newTitle.trimmed().isEmpty)
        }
        .alert(
            "Rename speaker",
            isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })
        ) {
            TextField("Name", text: $newSpeakerName)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Rename") {
                guard let label = renamingSpeaker else { return }
                renamingSpeaker = nil
                Task {
                    await model.renameSpeaker(label: label, in: meetingID, to: newSpeakerName)
                    await load()
                }
            }
        } message: {
            if let label = renamingSpeaker {
                Text("Every line by \(SpeakerLabel.display(label)) in this meeting. Leave empty to go back to \(SpeakerLabel.display(label)).")
            }
        }
                .sharePresentation(share)
        .sheet(isPresented: $composing) {
            if let meeting { ComposedShareView(meeting: meeting) }
        }
        .sheet(item: $editingSegment) { segment in
            SegmentEditor(segment: segment) { text in
                Task {
                    try? await model.store.updateSegmentText(segment.id, to: text)
                    await load()
                }
            }
        }
        .confirmationDialog("Redo the transcript?", isPresented: $confirmingRedoTranscript, titleVisibility: .visible) {
            Button("Redo transcript", role: .destructive) {
                if let meeting { redo(.transcript, meeting) }
            }
        } message: {
            Text("Your edits to this transcript are replaced by the new one.")
        }
        .confirmationDialog("Change speaker", isPresented: .constant(relabelling != nil), titleVisibility: .visible) {
            if let segment = relabelling, let meeting {
                ForEach(speakerLabels(meeting), id: \.self) { label in
                    Button(SpeakerLabel.name(label, names: meeting.speakerNames)) {
                        Task {
                            try? await model.store.relabelSegment(segment.id, to: label)
                            relabelling = nil
                            await load()
                        }
                    }
                }
                Button("Unknown") {
                    Task {
                        try? await model.store.relabelSegment(segment.id, to: nil)
                        relabelling = nil
                        await load()
                    }
                }
            }
            Button("Cancel", role: .cancel) { relabelling = nil }
        }
    }

    private func content(_ meeting: MeetingSnapshot) -> some View {
        VStack(spacing: 0) {
            if meeting.state != .complete {
                ProcessingStatusBanner(
                    meeting: meeting,
                    onStop: {
                        Task {
                            await model.stopProcessing(meeting.id)
                            await load()
                        }
                    },
                    onRetry: {
                        Task {
                            await model.retryProcessing(meeting.id, title: meeting.title)
                            pollGeneration += 1
                        }
                    }
                )
            }
            MeetingHeader(meeting: meeting)
                        Picker("View", selection: $tab) {
                Text("Summary").tag(Tab.summary)
                Text("Transcript").tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if tab == .transcript, player.isReady {
                PlayerBar(player: player, follow: $follow)
            }

            ScrollViewReader { proxy in
                List {
                    switch tab {
                    case .summary:
                        SummarySections(meeting: meeting, showsDetail: model.settings.debugMode) { segmentID in
                            // Tapping a citation jumps to the line it came from,
                            // and plays it. Every claim has one or it was not saved.
                            // Clear find so the cited line isn't filtered out.
                            find = ""
                            tab = .transcript
                            scrollTarget = segmentID
                            if let line = meeting.segments.first(where: { $0.id == segmentID }) {
                                player.play(from: line.start)
                            }
                        }
                    case .transcript:
                        TranscriptSections(
                            meeting: meeting,
                            playingID: player.isReady ? playingSegmentID(meeting) : nil,
                            terms: MeetingSearch.terms(find),
                            onPlay: { segment in
                                // From a find result: back to the whole transcript, at that line.
                                if !find.isEmpty {
                                    find = ""
                                    scrollTarget = segment.id
                                }
                                player.play(from: segment.start)
                            },
                            onEdit: { editingSegment = $0 },
                            onRelabel: { relabelling = $0 },
                            onRenameSpeaker: { label in
                                newSpeakerName = meeting.speakerNames[label] ?? ""
                                renamingSpeaker = label
                            },
                            showsModels: model.settings.debugMode
                        )
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
                .onChange(of: playingSegmentID(meeting)) { _, playing in
                    guard follow, player.isPlaying, tab == .transcript, let playing else { return }
                    withAnimation { proxy.scrollTo(playing, anchor: .center) }
                }
            }
        }
    }

    private func playingSegmentID(_ meeting: MeetingSnapshot) -> UUID? {
        TranscriptPlayback.currentIndex(at: player.currentTime, in: meeting.segments).map { meeting.segments[$0].id }
    }

    private func redo(_ stage: MeetingStore.RedoStage, _ meeting: MeetingSnapshot) {
        Task {
            await model.redo(stage, meetingID: meeting.id, title: meeting.title)
            pollGeneration += 1
        }
    }

    private func speakerLabels(_ meeting: MeetingSnapshot) -> [String] {
        let fromSegments = Set(meeting.segments.compactMap(\.speakerID))
        return Array(fromSegments.union(meeting.speakerNames.keys)).sorted()
    }

    private func load() async {
        meeting = try? await model.store.meetingSnapshot(meetingID)
    }

    /// Background processing (diarization, summarisation — including speaker-name
    /// inference) runs well after `stopRecording()` returns, inside a
    /// `BGContinuedProcessingTask` with no reference back to this view or to
    /// `AppModel`. Nothing else re-fetches this screen's snapshot when that finishes,
    /// so a meeting opened while still processing would otherwise show `.recording`/
    /// `.summarising`-era data (raw "S1" labels, no summary) forever, even after the
    /// pipeline completes. Poll gently until the state is terminal, then stop.
    private func showTranscriptIfFound() {
        let terms = MeetingSearch.terms(find)
        guard !terms.isEmpty, let meeting,
              meeting.segments.contains(where: { MeetingSearch.matches(MeetingSearch.normalize($0.text), terms: terms) })
        else { return }
        tab = .transcript
    }

    private func loadAndPollWhileProcessing() async {
        await load()
        while !Task.isCancelled {
            guard let meeting, !meeting.state.isTerminal else { return }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await load()
        }
    }
}

struct ProcessingStatusBanner: View {
    let meeting: MeetingSnapshot
    var onStop: () -> Void = {}
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if meeting.state == .failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(meeting.failureMessage ?? "Processing failed. It will resume from the last completed stage.")
                Spacer()
                Button("Try again", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if meeting.state == .queued, let waiting = meeting.failureMessage {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text(waiting)
            } else {
                ProgressView().controlSize(.small)
                Text(statusText)
                if let finish = meeting.estimatedCompletion {
                    let left = finish.timeIntervalSinceNow
                    Text(left > 0 ? "· \(left.roughDuration) left" : "· finishing up")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !meeting.state.isTerminal, meeting.state != .recording {
                Button(action: onStop) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop processing")
            }
        }
        .font(.footnote)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var statusText: String {
        switch meeting.state {
        case .queued: "Queued for processing"
        case .transcribing: "Transcribing…"
        case .diarizing: "Identifying speakers…"
        case .summarising: "Summarising…"
        case .recording: "Recording"
        default: ""
        }
    }
}

struct SummarySections: View {
    let meeting: MeetingSnapshot
    /// Debug mode: show the model's own error text under each Coverage line, and
    /// which model wrote the notes.
    var showsDetail = false
    var onCitation: (UUID) -> Void

    var body: some View {
        if let summary = meeting.summary {
            if !summary.overview.isEmpty {
                Section("Overview") { Text(summary.overview) }
            }
            ForEach(summary.topics ?? []) { topic in
                Section {
                    if !topic.summary.isEmpty {
                        Text(topic.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(topic.points) { point in
                        Button { onCitation(point.sourceSegmentID) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CitedRow(text: point.text, time: time(point.sourceSegmentID))
                                ForEach(point.details, id: \.self) { detail in
                                    Label(detail, systemImage: "circle.fill")
                                        .labelStyle(DetailBulletStyle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text([topic.emoji, topic.title].compactMap { $0 }.joined(separator: " "))
                }
            }
            if !summary.actionItems.isEmpty {
                Section("Action items") {
                    ForEach(ActionItem.groupedByOwner(summary.actionItems), id: \.owner) { group in
                        Text(group.owner)
                            .font(.subheadline.weight(.semibold))
                        ForEach(group.items) { item in
                            Button { onCitation(item.sourceSegmentID) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    CitedRow(text: item.task, time: time(item.sourceSegmentID))
                                    if let due = item.dueDate {
                                        Label(due, systemImage: "calendar")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !summary.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(summary.decisions) { decision in
                        Button { onCitation(decision.sourceSegmentID) } label: {
                            CitedRow(text: decision.statement, time: time(decision.sourceSegmentID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !summary.openQuestions.isEmpty {
                Section("Open questions") {
                    ForEach(summary.openQuestions) { question in
                        Button { onCitation(question.sourceSegmentID) } label: {
                            CitedRow(text: question.text, time: time(question.sourceSegmentID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !summary.mentionedSystems.isEmpty {
                Section("Systems mentioned") {
                    Text(summary.mentionedSystems.joined(separator: ", "))
                        .font(.callout)
                }
            }
            if !summary.degradedChunks.isEmpty {
                Section("Coverage") {
                    ForEach(Array(summary.degradedChunks.enumerated()), id: \.offset) { _, chunk in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                "\(Timecode.short(chunk.startTime))–\(Timecode.short(chunk.endTime)) \(chunk.explanation)",
                                systemImage: "exclamationmark.circle"
                            )
                            if showsDetail, let detail = chunk.detail {
                                Text(detail).font(.caption2.monospaced())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            // Debug mode: which model wrote the notes.
            if showsDetail, let credit = meeting.summaryCredit {
                Section {} footer: { ModelCredit(text: credit) }
            }
        } else {
            Section {
                ContentUnavailableView("No summary yet", systemImage: "text.badge.plus")
            }
        }
    }

    private func time(_ segmentID: UUID) -> String? {
        meeting.segments.first { $0.id == segmentID }.map { Timecode.short($0.start) }
    }
}

/// A small indented bullet for a point's supporting details.
private struct DetailBulletStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 4))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            configuration.title
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
    }
}

struct CitedRow: View {
    let text: String
    let time: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
            Spacer(minLength: 8)
            if let time {
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// The small print at the end of the notes or the transcript naming the model that
/// wrote them.
private struct ModelCredit: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }
}

struct TranscriptSections: View {
    let meeting: MeetingSnapshot
    /// The line under the playhead, highlighted.
    var playingID: UUID? = nil
    /// While finding: only the lines holding every word, with the words in bold.
    var terms: [String] = []
    var onPlay: (TranscriptSegment) -> Void = { _ in }
    var onEdit: (TranscriptSegment) -> Void
    var onRelabel: (TranscriptSegment) -> Void
    var onRenameSpeaker: (String) -> Void = { _ in }
    /// Debug mode: name the models that wrote the transcript and found the speakers.
    var showsModels = false

    var body: some View {
        let lines = terms.isEmpty
            ? meeting.segments
            : meeting.segments.filter { MeetingSearch.matches(MeetingSearch.normalize($0.text), terms: terms) }
        Section {
            if !terms.isEmpty {
                Text(lines.isEmpty ? "No lines match." : lines.count == 1 ? "1 line matches. Tap it to see it in place." : "\(lines.count) lines match. Tap one to see it in place.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(speakerName(segment))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colour(segment))
                            .onTapGesture {
                                if let label = segment.speakerID { onRenameSpeaker(label) }
                            }
                            .accessibilityAddTraits(segment.speakerID == nil ? [] : .isButton)
                            .accessibilityHint(segment.speakerID == nil ? "" : "Rename this speaker")
                        Text(Timecode.short(segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if segment.editedByUser {
                            Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(MeetingSearch.highlighted(segment.text, terms: terms))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onPlay(segment) }
                .listRowBackground(segment.id == playingID ? Color.accentColor.opacity(0.15) : nil)
                .id(segment.id)
                .contextMenu {
                    Button("Play from here", systemImage: "play") { onPlay(segment) }
                    if let label = segment.speakerID {
                        Button("Rename \(speakerName(segment))…", systemImage: "character.cursor.ibeam") { onRenameSpeaker(label) }
                    }
                    Button("Change speaker for this line", systemImage: "person.crop.circle") { onRelabel(segment) }
                    Button("Edit text", systemImage: "pencil") { onEdit(segment) }
                }
            }
        } footer: {
            if showsModels, terms.isEmpty, let credit = meeting.transcriptCredit {
                ModelCredit(text: credit)
            }
        }
    }

    private func speakerName(_ segment: TranscriptSegment) -> String {
        SpeakerLabel.name(segment.speakerID, names: meeting.speakerNames)
    }

    private func colour(_ segment: TranscriptSegment) -> Color {
        guard let id = segment.speakerID else { return .secondary }
        let labels = Array(Set(meeting.segments.compactMap(\.speakerID)))
        let rgb = SpeakerPalette.colours[SpeakerPalette.index(for: id, among: labels)]
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

struct SegmentEditor: View {
    let segment: TranscriptSegment
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(segment: TranscriptSegment, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(Timecode.short(segment.start))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                    }
                }
        }
    }
}

/// Play/pause, skip, scrubber and speed for the meeting's recording.
struct PlayerBar: View {
    let player: MeetingPlayer
    @Binding var follow: Bool
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.currentTime },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        player.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            HStack {
                Text(Timecode.short(scrubbing ?? player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44)
                }
                Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Button { player.cycleRate() } label: {
                    Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                Button { follow.toggle() } label: {
                    Image(systemName: follow ? "text.line.first.and.arrowtriangle.forward" : "text.justify.left")
                }
                .accessibilityLabel(follow ? "Stop following playback" : "Follow playback")
                Text(Timecode.short(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// When and where: the date and time, and the place if location was on.
struct MeetingHeader: View {
    let meeting: MeetingSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Text(meeting.startedAt.formatted(date: .complete, time: .shortened))
            if let latitude = meeting.latitude, let longitude = meeting.longitude,
               let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") {
                Text("·")
                // Opens the Maps app; Fieldnote itself makes no request.
                Link(destination: url) {
                    Label(meeting.placeName ?? String(format: "%.3f, %.3f", latitude, longitude), systemImage: "mappin")
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
