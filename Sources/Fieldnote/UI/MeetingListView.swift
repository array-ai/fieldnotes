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
    /// The record card's fields, kept here so the compact Record button starts the
    /// same meeting the card would.
    @State private var draftTitle = ""
    @State private var draftClient = ""
    @State private var isStarting = false
    @State private var startError: String?
    /// False once the record card scrolls out of view; the toolbar then shows a
    /// compact Record button.
    @State private var cardVisible = true

    /// The card is left out while searching, so it doesn't push the results down.
    private var showsCard: Bool {
        model.searchQuery.trimmed().isEmpty && !model.recorder.isActive
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                if model.recorder.isActive {
                    RecordingInProgressRow { showingRecorder = true }
                } else if showsCard {
                    RecordCard(
                        title: $draftTitle,
                        client: $draftClient,
                        isStarting: isStarting,
                        onStart: { Task { await startRecording() } },
                        startButtonVisible: { cardVisible = $0 }
                    )
                }
                Section {
                    ForEach(model.meetings) { meeting in
                        NavigationLink(value: meeting.id) {
                            MeetingRow(meeting: meeting)
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
                } header: {
                    if !model.meetings.isEmpty, showsCard { Text("Meetings") }
                }
            }
            .navigationTitle("Fieldnote")
            .navigationDestination(for: UUID.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .searchable(text: $model.searchQuery, prompt: "Search meetings")
            .toolbar {
                // The record card, shrunk, once it has scrolled away: starts the
                // meeting the card describes.
                if showsCard, !cardVisible {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await startRecording() }
                        } label: {
                            Label("Record", systemImage: "record.circle")
                                .labelStyle(.titleAndIcon)
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.white)
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.red)
                        .disabled(isStarting)
                        .accessibilityHint("Starts the meeting described in the card above")
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
                // Under the card when there's nothing else, so the card stays usable.
                if model.meetings.isEmpty, !showsCard {
                    ContentUnavailableView(
                        model.searchQuery.trimmed().isEmpty ? "No meetings yet" : "No matches",
                        systemImage: model.searchQuery.trimmed().isEmpty ? "waveform" : "magnifyingglass",
                        description: Text(
                            model.searchQuery.trimmed().isEmpty
                                ? "Everything you record stays on this device."
                                : "No meeting's title, client, place, speakers or notes match."
                        )
                    )
                }
            }
            .alert("Couldn't start recording", isPresented: Binding(
                get: { startError != nil },
                set: { if !$0 { startError = nil } }
            )) {
                Button("OK") { startError = nil }
            } message: {
                Text(startError ?? "")
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
        // A recording started from the Action button or a control: show it.
        .onChange(of: model.recorder.isActive) { _, active in
            if active { showingRecorder = true }
        }
        .onAppear { if model.recorder.isActive { showingRecorder = true } }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    /// Starts the meeting the record card describes. The recorder sheet opens when
    /// the recording is running (`onChange(of: isActive)` below).
    private func startRecording() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let typed = draftTitle.trimmed()
        let title = typed.isEmpty ? MeetingTitleGenerator.defaultTitle(type: .general) : typed
        do {
            model.settings.consentAcknowledged = true
            let coordinate = model.settings.locationEnabled ? await model.locationProvider.currentCoordinate() : nil
            try await model.startRecording(title: title, client: draftClient.trimmed().nilIfEmpty, coordinate: coordinate)
            draftTitle = ""
            draftClient = ""
        } catch {
            startError = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { model.meetings[$0].id }
        Task { await model.deleteMeetings(ids) }
    }
}

struct MeetingRow: View {
    let meeting: MeetingSnapshot

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
            // One line of details: who (the client), when (short, no year this year),
            // where, folder.
            // The place gives way first when space runs out.
            HStack(spacing: 4) {
                if let client = meeting.client {
                    Text(client)
                        .fontWeight(.medium)
                        .layoutPriority(3)
                    Text("·")
                }
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

            // The meeting at a glance: the first few sections of its notes.
            if let topics = meeting.summary?.topics, !topics.isEmpty {
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
