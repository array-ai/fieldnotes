import FieldnoteKit
import SwiftUI

struct RecorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var titleEditedByUser = false
    @State private var type: MeetingType = .general
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if model.recorder.isActive {
                    activeRecording
                } else {
                    setup
                }
            }
            .padding()
            .navigationTitle(model.recorder.isActive ? "Recording" : "New meeting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(model.recorder.isActive)
                }
            }
            .alert("Recording problem", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task {
                if title.isEmpty { title = MeetingTitleGenerator.defaultTitle(type: type) }
            }
        }
    }

    // MARK: - Before

    private var setup: some View {
        VStack(spacing: 20) {
            TextField("Meeting title", text: Binding(
                get: { title },
                set: { title = $0; titleEditedByUser = true }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3)

            Picker("Type", selection: $type) {
                ForEach(MeetingType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.symbolName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: type) { _, newType in
                guard !titleEditedByUser else { return }
                title = MeetingTitleGenerator.defaultTitle(type: newType)
            }

            Toggle("Include location", isOn: Bindable(model.settings).locationEnabled)
            Text("Stored as coordinates only, for your own reference. Never sent anywhere.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Text, not workflow (spec 7). The consent log, the badge and the share
            // gate are v2 (spec 11.5).
            Text(Self.consentNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button {
                Task { await start() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(title.trimmed().isEmpty)
        }
    }

    static let consentNotice = """
        Get everyone's agreement before you start. In NSW, recording a private \
        conversation generally needs the consent of every principal party \
        (Surveillance Devices Act 2007).
        """

    // MARK: - During

    private var activeRecording: some View {
        VStack(spacing: 20) {
            Text(Timecode.short(model.recorder.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())

            LevelMeter(level: model.recorder.level)
                .frame(height: 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.recorder.segments.suffix(12)) { segment in
                        Text(segment.text).font(.callout)
                    }
                    if !model.recorder.volatileText.isEmpty {
                        // Interim text. Shown, never persisted (spec 4.3).
                        Text(model.recorder.volatileText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Button {
                    Task {
                        if model.recorder.state == .paused {
                            await model.recorder.resume()
                        } else {
                            await model.recorder.pause()
                        }
                    }
                } label: {
                    Label(
                        model.recorder.state == .paused ? "Resume" : "Pause",
                        systemImage: model.recorder.state == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await model.stopRecording()
                        dismiss()
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)

            Text("Processing continues if you lock the phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func start() async {
        do {
            model.settings.consentAcknowledged = true
            let coordinate = model.settings.locationEnabled ? await model.locationProvider.currentCoordinate() : nil
            try await model.startRecording(title: title.trimmed(), type: type, coordinate: coordinate)
        } catch {
            self.error = error.localizedDescription
        }
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
