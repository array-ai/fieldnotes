import FieldnoteKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingRecorder = false
    @State private var showingSettings = false
    @State private var importing = false
    @State private var share = SharePresentation()
    @State private var path: [UUID] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                ForEach(model.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        MeetingRow(meeting: meeting, searchTerms: MeetingSearch.terms(model.searchQuery))
                    }
                    .contextMenu {
                        // Each payload is independently shareable from here as well as
                        // from the detail view (spec 6.1). The sheet itself is hosted
                        // on the list, not in here — see SharePayloadMenu.
                        SharePayloadMenu(meeting: meeting) { payload, format in
                            share.select(meeting: meeting, payload: payload, format: format)
                        }
                        if !meeting.state.isTerminal, meeting.state != .recording {
                            Divider()
                            Button("Stop processing", systemImage: "xmark.circle", role: .destructive) {
                                Task { await model.stopProcessing(meeting.id) }
                            }
                        } else if meeting.state == .failed {
                            Divider()
                            Button("Try again", systemImage: "arrow.clockwise") {
                                Task { await model.retryProcessing(meeting.id, title: meeting.title) }
                            }
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Fieldnote")
            .navigationDestination(for: UUID.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .searchable(text: $model.searchQuery, prompt: "Search meetings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingRecorder = true } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { importing = true } label: {
                        Label("Import recording", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.importProgress != nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.audio, .mpeg4Movie, .quickTimeMovie]
            ) { result in
                if case .success(let url) = result {
                    Task { await model.importRecording(from: url) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let progress = model.importProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Importing recording…").font(.footnote)
                        ProgressView(value: progress)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
            .alert("Import failed", isPresented: Binding(
                get: { model.importError != nil },
                set: { if !$0 { model.importError = nil } }
            )) {
                Button("OK") { model.importError = nil }
            } message: {
                Text(model.importError ?? "")
            }
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform",
                        description: Text("Everything you record stays on this device.")
                    )
                }
            }
            .refreshable { await model.refresh() }
            // Processing runs in the background and writes straight to the store, so
            // the list re-reads it while anything is in flight (the meeting screen
            // already polls the same way). Idle lists cost nothing.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if model.meetings.contains(where: { !$0.state.isTerminal }) {
                        await model.refresh()
                    }
                }
            }
            // Back from a meeting: show what happened while it was open.
            .onChange(of: path) { _, newPath in
                if newPath.isEmpty { Task { await model.refresh() } }
            }
        }
        .onChange(of: model.openMeetingID) { _, id in
            guard let id else { return }
            path = [id]
            model.openMeetingID = nil
        }
        .sharePresentation(share)
        .sheet(isPresented: $showingRecorder) { RecorderView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { model.meetings[$0].id }
        Task { await model.deleteMeetings(ids) }
    }
}

struct MeetingRow: View {
    let meeting: MeetingSnapshot
    /// While searching: show where the words were found instead of the topics.
    var searchTerms: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(meeting.title, systemImage: meeting.type.symbolName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if meeting.duration > 0 {
                    Text(Timecode.short(meeting.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // One line of details: when (short, no year this year), where, folder.
            // The place gives way first when space runs out.
            HStack(spacing: 4) {
                Text(Self.when(meeting.startedAt))
                    .layoutPriority(2)
                if let place = meeting.placeName, !place.isEmpty {
                    Text("·")
                    Label(place, systemImage: "mappin")
                        .labelStyle(.titleAndIcon)
                        .truncationMode(.tail)
                }
                if let folder = meeting.folderName {
                    Text("·")
                    Text(folder).layoutPriority(1)
                }
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)

            // Status on its own line, only while there is one.
            if meeting.state != .complete {
                ProcessingBadge(state: meeting.state, message: meeting.failureMessage, finish: meeting.estimatedCompletion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let snippet = MeetingSearch.snippet(in: meeting, terms: searchTerms) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let start = snippet.start {
                        Text(Timecode.short(start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "text.quote").foregroundStyle(.secondary)
                    }
                    Text(MeetingSearch.highlighted(snippet.text, terms: searchTerms))
                        .lineLimit(3)
                }
                .font(.subheadline)
                .padding(.top, 6)
            // The meeting at a glance: the first few sections of its notes.
            } else if let topics = meeting.summary?.topics, !topics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(topics.prefix(3)) { topic in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(topic.emoji ?? "•")
                            Text("\(Text(topic.title).bold())\(topic.summary.isEmpty ? "" : ": \(topic.summary)")")
                                .lineLimit(3)
                        }
                    }
                }
                .font(.subheadline)
                .padding(.top, 6)
            } else if let overview = meeting.summary?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }

    /// "6 Oct, 12:39 am"; the year only when it isn't this year.
    static func when(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
        return date.formatted(sameYear ? style : style.year())
    }
}

struct ProcessingBadge: View {
    let state: ProcessingState
    let message: String?
    var finish: Date?

    var body: some View {
        switch state {
        case .complete:
            EmptyView()
        case .failed:
            Label(message ?? "Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .recording:
            Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
        case .queued:
            Label(message == nil ? "Queued" : "Waiting to summarise", systemImage: message == nil ? "clock" : "hourglass")
        case .transcribing, .diarizing, .summarising:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(stageName)
                if let finish {
                    Text("· \(finish.timeIntervalSinceNow > 0 ? "\(max(0, finish.timeIntervalSinceNow).roughDuration) left" : "finishing")")
                }
            }
        }
    }

    private var stageName: String {
        switch state {
        case .transcribing: ProcessingStage.transcribing.displayName
        case .diarizing: ProcessingStage.diarizing.displayName
        case .summarising: ProcessingStage.summarising.displayName
        default: ""
        }
    }
}

extension MeetingSearch {
    /// The text with each search word in bold.
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(text)
        for term in terms {
            var searchFrom = text.startIndex
            while let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchFrom..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                searchFrom = range.upperBound
            }
        }
        return result
    }
}
