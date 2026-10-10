import EventKit
import FieldnoteKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var locales: [Locale] = []
    @State private var reminderLists: [(id: String, title: String)] = []
    private var downloads: ModelDownloads { .shared }

    private func transcriptionFooter(_ settings: AppModel.Settings) -> String {
        var text = "One language per recording. Changing this affects the next meeting, not existing ones."
        let engine = settings.transcriptionEngine
        if let pack = engine.modelPack {
            if !downloads.isInstalled(pack) {
                text += " \(engine.card.title) isn't downloaded yet, so Apple's model is used until it is."
            } else if !engine.supports(settings.localeIdentifier) {
                text += " \(engine.card.title) doesn't support this language, so Apple's model is used."
            } else if engine.runsLive {
                text += " \(engine.card.title) writes the live transcript while you record."
            } else {
                text += " The live transcript still comes from Apple's model; \(engine.card.title) rewrites it after you stop."
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
                    NavigationLink {
                        ModelsView(kind: .transcription)
                    } label: {
                        LabeledContent("Model", value: settings.transcriptionEngine.card.title)
                    }
                    NavigationLink {
                        CustomWordsView()
                    } label: {
                        LabeledContent("Custom words", value: settings.customWords.isEmpty ? "None" : "\(settings.customWords.count)")
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(transcriptionFooter(settings))
                }

                Section {
                    NavigationLink {
                        ModelsView(kind: .speakers)
                    } label: {
                        LabeledContent("Model", value: settings.diarizationMethod.card.title)
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
                    NavigationLink {
                        ModelsView(kind: .summary)
                    } label: {
                        LabeledContent("Notes model", value: settings.summaryEngine.card.title)
                    }
                    Toggle("Notify when notes are ready", isOn: $settings.notifyWhenProcessed)
                    Toggle("Finish notes while charging", isOn: $settings.summariseWhileCharging)
                    Toggle("Keep screen on while writing notes", isOn: $settings.keepAwakeWhileProcessing)
                    Toggle("Skip small talk in notes", isOn: $settings.skipSmallTalk)
                } header: {
                    Text("Processing")
                } footer: {
                    Text(
                        (settings.summaryEngine == .apple
                            ? "For clearer notes, try MiniCPM5 2B as the notes model (a 2.6 GB download): on an iPhone 16 it wrote a 68-minute meeting's notes in 3 minutes. "
                            : "") +
                        """
                        Apple's on-device model won't write notes in the background on \
                        battery. Transcripts and speakers always finish in the background; \
                        notes are written with Fieldnote open, or — with "Finish notes while \
                        charging" — whenever the phone is plugged in, even with the app \
                        closed (iOS picks the moment, often overnight). Notifications show \
                        the meeting title and first topic, which can appear on the lock screen.
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
                    Toggle("Let Siri read meeting notes", isOn: $settings.siriReadsNotes)
                } header: {
                    Text("Siri")
                } footer: {
                    Text(
                        """
                        Ask Siri for the action items or a summary of your last meeting. \
                        Siri gets only that answer, only when you ask, and only with the \
                        phone unlocked; nothing is added to Siri's or Spotlight's index. \
                        Siri may process requests off this device. To turn Siri off for \
                        Fieldnote completely, go to Settings → Apps → Fieldnote → Siri.
                        """
                    )
                }

                Section {
                    Toggle("Debug mode", isOn: $settings.debugMode)
                    if settings.debugMode {
                        NavigationLink("Activity log") { DebugLogView() }
                        NavigationLink("Benchmark models") { BenchmarkView() }
                        NavigationLink("Compare notes models") { NotesComparisonView() }
                        NavigationLink("Summary prompt") { SummaryPromptEditor() }
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text(
                        """
                        Shows a log of what ran, how long it took and what failed. It \
                        avoids meeting content, but an error message can include part \
                        of one, so read it before you share it.
                        """
                    )
                }

                Section {
                    Label("No accounts, no server, no network unless you choose it", systemImage: "network.slash")
                    Label("Audio, transcripts and summaries stay on this device", systemImage: "iphone")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(
                        """
                        Fieldnote goes online only to download models you choose, and for \
                        Apple Maps place names if you turn them on. Meeting content leaves \
                        the phone only when you share it, or when you ask Siri for your \
                        notes with that setting on.
                        """
                    )
                }

                // The last line: version, build and commit, as in the Activity log,
                // under the credits for the models and libraries.
                Section {
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                } footer: {
                    Text("Fieldnote \(DebugLog.appVersion)")
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                locales = await SpeechAssetProvisioner.supportedLocales()
                await loadReminderLists()
            }
            // Turned on just now, a list made in Reminders while this was open, or
            // back from the Reminders app: read the lists again.
            .onChange(of: settings.remindersEnabled) { _, _ in Task { await loadReminderLists() } }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                Task { await loadReminderLists() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadReminderLists() } }
            }
        }
    }
}

extension SettingsView {
    func loadReminderLists() async {
        let settings = model.settings
        guard settings.remindersEnabled else { return }
        let exporter = RemindersExporter()
        guard (try? await exporter.requestRemindersAccess()) == true else { return }
        reminderLists = await exporter.availableLists()
        // The chosen list was deleted in Reminders: fall back to the default.
        if let chosen = settings.remindersListID, !reminderLists.contains(where: { $0.id == chosen }) {
            settings.remindersListID = nil
        }
    }
}

struct DebugLogView: View {
    @State private var text = ""
    @State private var truncated = false
    @State private var confirmingClear = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(
                    "Fieldnote \(DebugLog.appVersion)\n\n"
                        + (truncated ? "Showing the newest entries. Share sends the whole log.\n\n" : "")
                        + (text.isEmpty ? "Nothing logged yet." : text)
                )
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
        (text, truncated) = DebugLog.shared.contents()
    }
}

/// Debug mode: one meeting's notes from every notes model, as a report to share.
struct NotesComparisonView: View {
    @Environment(AppModel.self) private var model
    @State private var comparison = NotesComparison()
    @State private var meetingID: UUID?
    @State private var includeTranscript = true

    private var busy: Bool {
        model.meetings.contains { !$0.state.isTerminal && $0.state != .recording } || model.recorder.isActive
    }

    private var candidates: [MeetingSnapshot] {
        model.meetings.filter { $0.state == .complete && !$0.segments.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Meeting", selection: $meetingID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(candidates) { meeting in
                        Text(meeting.title).tag(UUID?.some(meeting.id))
                    }
                }
                Toggle("Include the transcript", isOn: $includeTranscript)
                Button {
                    guard let meeting = candidates.first(where: { $0.id == meetingID }) else { return }
                    Task { await comparison.run(on: meeting, includeTranscript: includeTranscript) }
                } label: {
                    if comparison.isRunning {
                        HStack {
                            ProgressView()
                            Text(comparison.status)
                        }
                    } else {
                        Text("Write notes with every model")
                    }
                }
                .disabled(meetingID == nil || comparison.isRunning || busy)
            } footer: {
                Text(
                    """
                    \(busy ? "Available once nothing is recording or processing. " : "")Writes this \
                    meeting's notes with each downloaded model, one after another, the way \
                    processing does. The meeting keeps its own notes. Takes a few minutes per \
                    model; keep the app open. The report holds the notes, and the transcript \
                    if included, which is needed to check them against what was said: share \
                    it only where you're happy for that to go.
                    """
                )
            }

            if !comparison.results.isEmpty {
                Section("Results") {
                    ForEach(comparison.results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.engine.card.title).font(.subheadline.weight(.semibold))
                            Text(result.line)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if !result.thermal.isEmpty {
                                Text("Thermal state: \(result.thermal)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let ranOn = result.ranOn, ranOn != result.engine.card.title {
                                Text("Ran on \(ranOn)").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if let url = comparison.reportURL {
                        ShareLink(item: url) {
                            Label("Share the report", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .navigationTitle("Compare notes models")
        .navigationBarTitleDisplayMode(.inline)
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


/// Model cards for one job (transcription or speakers): what each model is good at,
/// relative accuracy and speed, languages, size, and download / delete. Tap a card to
/// use that model.
struct ModelsView: View {
    enum Kind { case transcription, speakers, summary }

    let kind: Kind
    @Environment(AppModel.self) private var model
    private var downloads: ModelDownloads { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch kind {
                case .transcription:
                    ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                        card(engine.card, pack: engine.modelPack, active: model.settings.transcriptionEngine == engine) {
                            model.settings.transcriptionEngine = engine
                        } onDeleted: {
                            if model.settings.transcriptionEngine == engine { model.settings.transcriptionEngine = .apple }
                        }
                    }
                case .summary:
                    ForEach(SummaryEngine.allCases, id: \.self) { engine in
                        card(engine.card, pack: engine.modelPack, active: model.settings.summaryEngine == engine) {
                            model.settings.summaryEngine = engine
                        } onDeleted: {
                            if model.settings.summaryEngine == engine { model.settings.summaryEngine = .apple }
                        }
                    }
                case .speakers:
                    ForEach(DiarizationMethod.allCases, id: \.self) { method in
                        card(method.card, pack: method.modelPack, active: model.settings.diarizationMethod == method) {
                            model.settings.diarizationMethod = method
                        } onDeleted: {
                            if model.settings.diarizationMethod == method { model.settings.diarizationMethod = .nemotron3 }
                        }
                    }
                }
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding()
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch kind {
        case .transcription: "Transcription models"
        case .speakers: "Speaker models"
        case .summary: "Notes models"
        }
    }

    private var footer: String {
        """
        Accuracy and speed are relative, from published error rates and a benchmark on \
        an iPhone 16 Pro; run Settings → Debug → Benchmark models for this phone. \
        Downloads come from Hugging Face only when you tap Download, at a fixed \
        version, with every file checked against its published checksum. Downloads \
        carry on in the background; keep Fieldnote open while a model prepares.
        """
    }

    private func card(
        _ card: ModelCard,
        pack: ModelPack.ID?,
        active: Bool,
        select: @escaping () -> Void,
        onDeleted: @escaping () -> Void
    ) -> some View {
        let state: ModelDownloads.State = pack.map { downloads.state($0) } ?? .installed
        return ModelCardView(
            card: card,
            size: pack.map { ModelPack.pack($0).totalBytes.byteCountDescription } ?? "Built in",
            state: state,
            isBuiltIn: pack == nil,
            isActive: active && state == .installed,
            onSelect: { if state == .installed { select() } },
            onDownload: { if let pack { downloads.download(pack) } },
            onCancel: { if let pack { downloads.cancel(pack) } },
            onDelete: {
                if let pack {
                    downloads.delete(pack)
                    onDeleted()
                }
            }
        )
    }
}

/// The user's own words, and the download that puts them into Parakeet transcripts.
struct CustomWordsView: View {
    @Environment(AppModel.self) private var model
    @State private var newWord = ""
    private var downloads: ModelDownloads { .shared }
    private let pack = ModelPack.ID.parakeetCtcWords

    private func add() {
        model.settings.customWords = CustomWords.merged(user: model.settings.customWords + [newWord], builtIn: [])
        newWord = ""
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                HStack {
                    TextField("Add a word or name", text: $newWord)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.customWords, id: \.self) { Text($0) }
                    .onDelete { settings.customWords.remove(atOffsets: $0) }
            } footer: {
                Text("Spell them as the transcript should: products, people, places. They add to the built-in list below and apply to the next transcript, or a redone one.")
            }

            Section {
                Toggle("Clean up with the notes model", isOn: $settings.cleanUpCustomWords)
            } footer: {
                Text(
                    """
                    Before writing notes, the notes model reads the lines with a word close \
                    to one of these and fixes the ones that clearly mean it, judging by \
                    context: "sync row" in a line about tickets becomes Syncro, "the team" \
                    stays a team. Works with any transcription model; adds a minute or two \
                    to a long meeting.
                    """
                )
            }

            Section {
                fixer
            } header: {
                Text("Parakeet")
            } footer: {
                Text(
                    """
                    Parakeet can't be told words in advance. With this download, a small \
                    model listens again after Parakeet and swaps a misheard word only when \
                    the audio supports yours. Apple's model gets the words directly.
                    """
                )
            }

            Section("Built in") {
                Text(MSPVocabulary.contextualStrings.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Custom words")
    }

    @ViewBuilder
    private var fixer: some View {
        let size = ModelPack.pack(pack).totalBytes.byteCountDescription
        switch downloads.state(pack) {
        case .notInstalled:
            Button("Download word checker (\(size))", systemImage: "arrow.down.circle") { downloads.download(pack) }
        case .failed(let message):
            Button("Download word checker (\(size))", systemImage: "arrow.down.circle") { downloads.download(pack) }
            Text(message).font(.caption).foregroundStyle(.red)
        case .downloading(let fraction):
            ProgressView(value: fraction)
            Button("Cancel", role: .cancel) { downloads.cancel(pack) }
        case .preparing:
            LabeledContent("Preparing for this phone") { ProgressView().controlSize(.small) }
        case .installed:
            LabeledContent("Word checker", value: "Downloaded, \(size)")
            Button("Delete", systemImage: "trash", role: .destructive) { downloads.delete(pack) }
        }
    }
}

struct ModelCardView: View {
    let card: ModelCard
    let size: String
    let state: ModelDownloads.State
    let isBuiltIn: Bool
    let isActive: Bool
    var onSelect: () -> Void
    var onDownload: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(card.title).font(.headline)
                        if isActive {
                            Label("Active", systemImage: "checkmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(card.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    RatingBar(label: "accuracy", value: card.accuracy)
                    RatingBar(label: "speed", value: card.speed)
                }
            }

            switch state {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                Text("Keeps downloading if you lock the phone or leave the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .preparing:
                Text("Preparing for this phone, once. This can take a few minutes: keep Fieldnote open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }

            Divider()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(card.languages, systemImage: "globe")
                    Label(card.runs, systemImage: "waveform")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label(size, systemImage: "internaldrive")
                    action
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notInstalled, .failed:
            Button("Download", systemImage: "arrow.down.circle", action: onDownload)
                .labelStyle(.titleAndIcon)
        case .downloading:
            Button("Cancel", role: .cancel, action: onCancel)
        case .preparing:
            ProgressView().controlSize(.small)
        case .installed:
            if !isBuiltIn {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// A short labelled bar, 0...1.
struct RatingBar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: 64 * min(1, max(0, value)))
            }
            .frame(width: 64, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int((value * 100).rounded())) percent")
    }
}
