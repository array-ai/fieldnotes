import FieldnoteKit
import SwiftUI

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingRecorder = false
    @State private var showingSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                ForEach(model.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        MeetingRow(meeting: meeting)
                    }
                    .contextMenu {
                        // Each payload is independently shareable from here as well as
                        // from the detail view (spec 6.1).
                        SharePayloadMenu(meeting: meeting)
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
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
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
                ProcessingBadge(state: meeting.state, message: meeting.failureMessage)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ProcessingBadge: View {
    let state: ProcessingState
    let message: String?

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
            Label("Queued", systemImage: "clock")
        case .transcribing, .diarizing, .summarising:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(stageName)
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
