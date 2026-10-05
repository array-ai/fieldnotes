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
        Task {
            for id in ids { try? await model.store.delete(meetingID: id) }
            await model.refresh()
        }
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
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let folder = meeting.folderName {
                    Text("·")
                    Text(folder)
                }
                Spacer()
                ProcessingBadge(state: meeting.state, message: meeting.failureMessage, finish: meeting.estimatedCompletion)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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
                    Text("· \(finish.timeIntervalSinceNow > 0 ? max(0, finish.timeIntervalSinceNow).roughDuration : "finishing")")
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
