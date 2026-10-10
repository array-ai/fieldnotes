import FieldnoteKit
import SwiftUI

/// The top of the meeting list: what the next meeting is called, who it's with,
/// whether to note where it is, and Start recording. Replaces the separate setup
/// screen, so a recording is one tap from opening the app.
struct RecordCard: View {
    @Environment(AppModel.self) private var model
    @Binding var title: String
    @Binding var client: String
    var isStarting: Bool
    var onStart: () -> Void
    /// Whether Start recording is on screen, for the list's compact Record button.
    var startButtonVisible: (Bool) -> Void = { _ in }

    var body: some View {
        Section {
            // An empty title takes the suggested one, shown as the placeholder.
            TextField("Meeting title", text: $title, prompt: Text(MeetingTitleGenerator.defaultTitle(type: .general)))
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
            LabeledContent("Client") {
                TextField("Client", text: $client, prompt: Text("Add client or company"))
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
            Toggle("Location", isOn: Bindable(model.settings).locationEnabled)
            Button(action: onStart) {
                Label("Start recording", systemImage: "record.circle")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.red)
            .disabled(isStarting)
            .listRowSeparator(.hidden)
            .onScrollVisibilityChange(threshold: 0.5, startButtonVisible)
        } header: {
            Text("New meeting")
        } footer: {
            // Text, not workflow (spec 7). The consent log, the badge and the share
            // gate are v2 (spec 11.5).
            Text(Self.consentNotice)
        }
    }

    static let consentNotice = """
        Get everyone's agreement before you start. In NSW, recording a private \
        conversation generally needs the consent of every principal party \
        (Surveillance Devices Act 2007).
        """
}

/// Shown in the card's place while a recording runs: the way back to Stop.
struct RecordingInProgressRow: View {
    @Environment(AppModel.self) private var model
    var onOpen: () -> Void

    var body: some View {
        Section {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: model.recorder.state == .recording)
                    Text(model.recorder.state.label)
                        .font(.headline)
                    Spacer()
                    Text(Timecode.short(model.recorder.elapsed))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Opens the recording")
        }
    }
}

extension RecordingController.State {
    /// What the recorder is doing, in a word or two, for the recorder's title.
    var label: String {
        switch self {
        case .idle, .preparing: "Starting…"
        case .recording: "Recording"
        case .paused, .interrupted: "Paused"
        case .stopping: "Saving…"
        case .failed: "Stopped"
        }
    }
}
