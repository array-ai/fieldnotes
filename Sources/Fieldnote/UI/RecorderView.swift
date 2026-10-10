import FieldnoteKit
import SwiftUI

struct RecorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The meeting's title and client, editable while recording. Loaded once from the
    /// meeting; saved on Return, on Stop and when the sheet closes.
    @State private var title = ""
    @State private var client = ""
    @State private var loaded = false
    /// The meeting read from the store, for when the list is filtered by a search.
    @State private var stored: MeetingSnapshot?

    var body: some View {
        NavigationStack {
            Group {
                if model.recorder.isActive {
                    activeRecording
                } else {
                    ProgressView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            // A swipe down mustn't leave a recording running with no way back to Stop.
            .interactiveDismissDisabled(model.recorder.isActive)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ✕ stops and saves, the same as Stop: there is no "close and keep
                // recording" here, and no way to lose a recording by closing.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stop and save", systemImage: "xmark") { stop() }
                        .disabled(!model.recorder.isActive || model.recorder.state == .stopping)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, isActive: model.recorder.state == .recording)
                        Text(model.recorder.state.label).font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .task {
                if let id = model.recorder.meetingID, meeting == nil {
                    stored = try? await model.store.meetingSnapshot(id)
                }
                load()
            }
            .onChange(of: model.meetings) { load() }
            .onDisappear { save() }
        }
    }

    // MARK: - During

    private var activeRecording: some View {
        VStack(spacing: 12) {
            Text(Timecode.short(model.recorder.elapsed))
                .font(.system(size: 60, weight: .light, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .accessibilityLabel("Recorded \(Timecode.short(model.recorder.elapsed))")

            LevelMeter(level: model.recorder.level)
                .frame(height: 12)
                .accessibilityHidden(true)

            if let notice = recorderNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            details
                .padding(.top, 6)

            Text("Live transcript")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recentLines) { segment in
                        VStack(alignment: .leading, spacing: 1) {
                            if let speaker = segment.speakerID {
                                Text(SpeakerLabel.display(speaker))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.text)
                        }
                    }
                    if !model.recorder.volatileText.isEmpty {
                        // Interim text. Shown, never persisted (spec 4.3).
                        Text(model.recorder.volatileText)
                            .foregroundStyle(.secondary)
                    }
                    if recentLines.isEmpty, model.recorder.volatileText.isEmpty {
                        Text("Listening…")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)

            HStack(spacing: 12) {
                if !isFailed {
                    Button {
                        Task {
                            if canResume {
                                await model.recorder.resume()
                            } else {
                                await model.recorder.pause()
                            }
                        }
                    } label: {
                        Label(
                            canResume ? "Resume" : "Pause",
                            systemImage: canResume ? "play.fill" : "pause.fill"
                        )
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.recorder.state == .preparing || model.recorder.state == .stopping)
                }

                Button { stop() } label: {
                    Label(isFailed ? "Save recording" : "Stop", systemImage: "stop.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.recorder.state == .stopping)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            Text("Processing continues if you lock the phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Title, client and place, as on the record card, editable while recording.
    private var details: some View {
        VStack(spacing: 0) {
            TextField("Meeting title", text: $title)
                .font(.headline)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            Divider().padding(.leading, 16)
            HStack(spacing: 12) {
                Text("Client")
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                TextField("Client", text: $client, prompt: Text("Add client or company"))
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            if let meeting, meeting.latitude != nil {
                Divider().padding(.leading, 16)
                HStack(spacing: 12) {
                    Text("Place")
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    Label(meeting.placeName ?? "Finding the place…", systemImage: "mappin")
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The meeting being recorded, as the list last read it (with its place name,
    /// which arrives a moment after the start).
    private var meeting: MeetingSnapshot? {
        model.meetings.first { $0.id == model.recorder.meetingID } ?? stored
    }

    private func load() {
        guard !loaded, let meeting else { return }
        loaded = true
        title = meeting.title
        client = meeting.client ?? ""
    }

    /// Writes the title and client back, if they changed.
    private func save() {
        guard loaded, let meeting else { return }
        let id = meeting.id
        let newTitle = title.trimmed()
        let newClient = client.trimmed()
        Task {
            if !newTitle.isEmpty, newTitle != meeting.title {
                await model.renameMeeting(id, to: newTitle)
            }
            if newClient != (meeting.client ?? "") {
                await model.setClient(id, to: newClient)
            }
        }
    }

    private func stop() {
        save()
        Task {
            await model.stopRecording()
            dismiss()
        }
    }

    private var canResume: Bool {
        model.recorder.state == .paused || model.recorder.state == .interrupted
    }

    private var isFailed: Bool {
        if case .failed = model.recorder.state { return true }
        return false
    }

    /// Why the recording isn't capturing, when it isn't.
    private var recorderNotice: String? {
        switch model.recorder.state {
        case .interrupted:
            "Recording paused by a call or another app. Tap Resume to carry on."
        case .failed(let message):
            "Recording stopped by a problem. What was recorded is saved; tap Save recording. (\(message))"
        default:
            nil
        }
    }

    /// The last lines, labelled with whoever live identification says spoke them.
    /// Lines newer than the model's ~10 s window stay unlabelled until it catches up.
    private var recentLines: [TranscriptSegment] {
        let lines = Array(model.recorder.segments.suffix(12))
        guard !model.recorder.liveSpans.isEmpty else { return lines }
        return WordSpeakerSplit.apply(spans: model.recorder.liveSpans, to: lines)
    }
}

struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: proxy.size.width * min(1, max(0.02, level)))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}
