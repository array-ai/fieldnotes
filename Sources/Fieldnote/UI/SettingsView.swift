import FieldnoteKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var locales: [Locale] = []
    @State private var reminderLists: [(id: String, title: String)] = []
    private var downloads: ModelDownloads { .shared }

    private func transcriptionFooter(_ settings: AppModel.Settings) -> String {
        var text = "One language per recording. Changing this affects the next meeting, not existing ones."
        if settings.transcriptionEngine == .parakeet {
            if !downloads.isInstalled(.parakeetV3) {
                text += " Parakeet isn't downloaded yet, so Apple's model is used until it is."
            } else if !TranscriptionEngine.parakeetSupports(settings.localeIdentifier) {
                text += " Parakeet doesn't support this language, so Apple's model is used."
            } else {
                text += " The live transcript still comes from Apple's model; Parakeet rewrites it after you stop."
            }
        }
        return text
    }

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                // Section takes a title string *or* a footer, not both: with a
                // trailing footer the content closure has to be the labelled one.
                Section {
                    Picker("Language", selection: $settings.localeIdentifier) {
                        ForEach(locales, id: \.identifier) { locale in
                            Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    Picker("Model", selection: $settings.transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine == .parakeet && !downloads.isInstalled(.parakeetV3)
                                 ? "\(engine.displayName) — download in Models"
                                 : engine.displayName)
                                .tag(engine)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(transcriptionFooter(settings))
                }

                Section {
                    Picker("Method", selection: $settings.diarizationMethod) {
                        ForEach(DiarizationMethod.allCases, id: \.self) { method in
                            Text(method.isInstalled ? method.displayName : "\(method.displayName) — download in Models")
                                .tag(method)
                        }
                    }
                    if settings.diarizationMethod == .nemotron3 {
                        Toggle("Identify while recording", isOn: $settings.liveSpeakers)
                    }
                } header: {
                    Text("Speaker identification")
                } footer: {
                    Text(
                        """
                        \(settings.diarizationMethod.summary) Runs on this device. \
                        \(settings.diarizationMethod.isInstalled ? "" : "Not downloaded yet, so Nemotron 3 is used until it is. ")\
                        \(settings.identifiesSpeakersLive ? "Speakers are labelled about ten seconds behind the conversation, and are ready when you stop. " : "")\
                        Changing this affects the next meeting, not existing ones.
                        """
                    )
                }

                Section {
                    ForEach(ModelPack.catalog) { pack in
                        ModelPackRow(pack: pack)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text(
                        """
                        Optional, and only downloaded when you tap Download: from \
                        Hugging Face, at a fixed version, with every file checked \
                        against its published checksum. Nothing else is sent. Keep \
                        Fieldnote open while a download runs. Nemotron 3 and Apple's \
                        speech model are built in.
                        """
                    )
                }

                Section {
                    Toggle("Send tasks to Reminders", isOn: $settings.remindersEnabled)
                    if settings.remindersEnabled {
                        Picker("List", selection: $settings.remindersListID) {
                            Text("Default").tag(String?.none)
                            ForEach(reminderLists, id: \.id) { list in
                                Text(list.title).tag(String?.some(list.id))
                            }
                        }
                    }
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Reminders stay on this device and in your own iCloud, if you use it. Fieldnote never sends them anywhere.")
                }

                Section {
                    Toggle("Notify when notes are ready", isOn: $settings.notifyWhenProcessed)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A notification on this phone when a meeting finishes processing. It shows the meeting title and its first topic, which can appear on the lock screen.")
                }

                Section {
                    Toggle("Name places with Apple Maps", isOn: $settings.appleMapsPlaceNames)
                } header: {
                    Text("Location")
                } footer: {
                    Text(
                        """
                        Meetings recorded with location get the nearest suburb or town \
                        from a list built into the app, without going online. Turn this \
                        on to also look up the business, building or street with Apple \
                        Maps: that sends the meeting's coordinates to Apple, and nothing \
                        else.
                        """
                    )
                }

                Section {
                    Toggle("Debug mode", isOn: $settings.debugMode)
                    if settings.debugMode {
                        NavigationLink("Activity log") { DebugLogView() }
                        NavigationLink("Benchmark models") { BenchmarkView() }
                        NavigationLink("Summary prompt") { SummaryPromptEditor() }
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text(
                        """
                        Shows a log of what ran and how long it took, and adds Redo \
                        actions to each meeting. The log holds timings and errors only, \
                        never what was said.
                        """
                    )
                }

                Section("Backup") {
                    NavigationLink("Export or restore") { BackupView() }
                }

                Section {
                    Label("No accounts, no server, no network unless you choose it", systemImage: "network.slash")
                    Label("Audio, transcripts and summaries stay on this device", systemImage: "iphone")
                    Label("Nothing is added to Spotlight or Siri", systemImage: "magnifyingglass")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(
                        """
                        Fieldnote goes online only for model downloads you tap and Apple \
                        Maps place names if you turn them on. Meeting content leaves only \
                        when you drive the share sheet yourself, and then it is the \
                        destination app's business, not Fieldnote's.
                        """
                    )
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                locales = await SpeechAssetProvisioner.supportedLocales()
                if settings.remindersEnabled {
                    let exporter = RemindersExporter()
                    if (try? await exporter.requestRemindersAccess()) == true {
                        reminderLists = await exporter.availableLists()
                    }
                }
            }
        }
    }
}

struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var passphrase = ""
    @State private var status: String?
    @State private var exportURL: URL?

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase", text: $passphrase)
                Button("Create encrypted archive") { Task { await export() } }
                    .disabled(passphrase.count < 8)
            } header: {
                Text("Export")
            } footer: {
                Text(
                    """
                    One encrypted file you keep wherever you choose. There is no cloud \
                    copy, and a lost passphrase cannot be recovered.
                    """
                )
            }
            if let status {
                Section { Text(status).font(.footnote) }
            }
            if let exportURL {
                Section { ShareLink(item: exportURL) { Label("Share archive", systemImage: "square.and.arrow.up") } }
            }
        }
        .navigationTitle("Backup")
    }

    private func export() async {
        do {
            let meetings = try await model.store.recentSnapshots(limit: 10_000)
            let payload = BackupArchive.Payload(
                manifest: .init(createdAt: Date(), meetingCount: meetings.count, includesAudio: false),
                meetings: meetings.map { meeting in
                    BackupArchive.MeetingBackup(
                        id: meeting.id,
                        title: meeting.title,
                        type: meeting.type,
                        startedAt: meeting.startedAt,
                        duration: meeting.duration,
                        localeIdentifier: Locale.current.identifier,
                        folderName: meeting.folderName,
                        segments: meeting.segments,
                        speakerNames: meeting.speakerNames,
                        speakerEmbeddings: [:],
                        summary: meeting.summary,
                        latitude: meeting.latitude,
                        longitude: meeting.longitude,
                        placeName: meeting.placeName
                    )
                }
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fieldnote \(ExportFilename.isoDate(Date())).fieldnote")
            try BackupArchive.write(payload, passphrase: passphrase, to: url)
            exportURL = url
            status = "Archived \(payload.meetings.count) meetings."
        } catch {
            status = error.localizedDescription
        }
    }
}

struct DebugLogView: View {
    @State private var text = ""
    @State private var confirmingClear = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text("Fieldnote \(DebugLog.appVersion)\n\n" + (text.isEmpty ? "Nothing logged yet." : text))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle("Activity log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") { reload() }
                ShareLink(item: DebugLog.shared.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button("Clear", systemImage: "trash", role: .destructive) { confirmingClear = true }
            }
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                DebugLog.shared.clear()
                reload()
            }
        }
        .task { reload() }
    }

    private func reload() {
        text = DebugLog.shared.contents()
    }
}

struct BenchmarkView: View {
    @Environment(AppModel.self) private var model
    @State private var benchmark = ModelBenchmark()
    @State private var meetingID: UUID?

    /// The benchmark competes with real processing for the same models (and the
    /// summary model rate-limits concurrent requests), so it waits its turn.
    private var processing: Bool {
        model.meetings.contains { !$0.state.isTerminal && $0.state != .recording }
    }

    private var candidates: [MeetingSnapshot] {
        model.meetings.filter { $0.state == .complete && $0.duration > 0 }
    }

    var body: some View {
        Form {
            Section {
                Picker("Recording", selection: $meetingID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(candidates) { meeting in
                        Text(meeting.title).tag(UUID?.some(meeting.id))
                    }
                }
                Button {
                    guard let meeting = candidates.first(where: { $0.id == meetingID }) else { return }
                    Task { await benchmark.run(on: meeting, locale: model.settings.locale) }
                } label: {
                    if benchmark.isRunning {
                        HStack {
                            ProgressView()
                            Text(benchmark.status)
                        }
                    } else {
                        Text("Run benchmark")
                    }
                }
                .disabled(meetingID == nil || benchmark.isRunning || model.recorder.isActive || processing)
            } footer: {
                Text(
                    """
                    \(processing ? "Available once meetings finish processing. " : "")Times each speaker model (cold and warm load, then up to five \
                    minutes of the recording), Apple's speech model on the first five \
                    minutes, and the summary model on one excerpt. Takes a minute or \
                    two and warms the phone. Results also go to the Activity log.
                    """
                )
            }

            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(benchmark.rows.filter { $0.section == section }) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.subheadline.weight(.semibold))
                            Text(row.value)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Benchmark")
        .toolbar {
            if !benchmark.rows.isEmpty, !benchmark.isRunning {
                ShareLink(item: benchmark.report) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .task {
            if meetingID == nil { meetingID = candidates.first?.id }
        }
    }

    private var sections: [String] {
        var seen: [String] = []
        for row in benchmark.rows where !seen.contains(row.section) { seen.append(row.section) }
        return seen
    }
}

struct SummaryPromptEditor: View {
    @State private var prompt = SummaryPromptStore.load()
    @State private var saved = SummaryPromptStore.load()

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt.preamble).frame(minHeight: 100)
            } header: {
                Text("Instructions")
            } footer: {
                Text("The system prompt: who the model is and what the notes are for.")
            }
            Section {
                TextEditor(text: $prompt.request).frame(minHeight: 140)
            } header: {
                Text("Request for each excerpt")
            } footer: {
                Text("Sent with every part of the transcript. Ask for what you want pulled out; the topics, decisions, tasks and questions it fills in are fixed.")
            }
            Section {
                Text(PromptTemplates.groundingRules)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("Always added")
            } footer: {
                Text("These rules make points cite the transcript, which is how they get timestamps and how made-up points are dropped. They can't be edited.")
            }
            Section {
                Button("Restore built-in prompt", role: .destructive) {
                    prompt = .builtIn
                    save()
                }
                .disabled(prompt.isBuiltIn)
            } footer: {
                Text("Changes apply to the next summary. Use Redo summary on a meeting to compare. Smaller on-device models follow short, plain instructions best.")
            }
        }
        .navigationTitle("Summary prompt")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(prompt == saved)
            }
        }
    }

    private func save() {
        SummaryPromptStore.save(prompt)
        saved = prompt
        DebugLog.shared.log("summary", prompt.isBuiltIn ? "summary prompt restored to built-in" : "summary prompt edited")
    }
}

struct ModelPackRow: View {
    let pack: ModelPack
    private var downloads: ModelDownloads { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.name)
                    Text("\(pack.totalBytes.byteCountDescription) · \(pack.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch downloads.state(pack.id) {
                case .notInstalled, .failed:
                    Button("Download") { downloads.download(pack.id) }
                        .buttonStyle(.bordered)
                case .downloading:
                    Button("Cancel", role: .cancel) { downloads.cancel(pack.id) }
                        .buttonStyle(.bordered)
                case .preparing:
                    ProgressView()
                case .installed:
                    Button("Delete", role: .destructive) { downloads.delete(pack.id) }
                        .buttonStyle(.bordered)
                }
            }
            if case .downloading(let fraction) = downloads.state(pack.id) {
                ProgressView(value: fraction)
            }
            if case .preparing = downloads.state(pack.id) {
                Text("Preparing for this phone… this can take a few minutes, once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = downloads.state(pack.id) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
