import FieldnoteKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var locales: [Locale] = []
    @State private var reminderLists: [(id: String, title: String)] = []

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
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("One language per recording. Changing this affects the next meeting, not existing ones.")
                }

                Section {
                    Picker("Method", selection: $settings.diarizationMethod) {
                        ForEach(DiarizationMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                } header: {
                    Text("Speaker identification")
                } footer: {
                    Text(
                        """
                        \(settings.diarizationMethod.summary) Runs on this device. \
                        Changing this affects the next meeting, not existing ones.
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
                    Toggle("Debug mode", isOn: $settings.debugMode)
                    if settings.debugMode {
                        NavigationLink("Activity log") { DebugLogView() }
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
                    Label("No accounts, no server, no network", systemImage: "network.slash")
                    Label("Audio, transcripts and summaries stay on this device", systemImage: "iphone")
                    Label("Nothing is added to Spotlight or Siri", systemImage: "magnifyingglass")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(
                        """
                        Fieldnote makes no outbound requests. Content leaves only when \
                        you drive the share sheet yourself, and then it is the \
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
                        longitude: meeting.longitude
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
                Text(text.isEmpty ? "Nothing logged yet." : text)
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
