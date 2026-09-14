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

                Section("Templates") {
                    NavigationLink("Summary templates") { TemplateListView() }
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

struct TemplateListView: View {
    @State private var editing: SummaryTemplate?

    var body: some View {
        List(MeetingType.allCases, id: \.self) { type in
            Button {
                Task { editing = await TemplateStore.shared.template(for: type) }
            } label: {
                Label(type.displayName, systemImage: type.symbolName)
            }
        }
        .navigationTitle("Templates")
        .sheet(item: $editing) { template in
            TemplateEditor(template: template)
        }
    }
}

struct TemplateEditor: View {
    @State var template: SummaryTemplate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Instructions") {
                    TextEditor(text: $template.instructions).frame(minHeight: 160)
                }
                Section {
                    TextEditor(text: $template.focus).frame(minHeight: 100)
                } header: {
                    Text("Focus")
                } footer: {
                    Text(
                        """
                        Prompt edits are code changes with no compiler. Re-run your \
                        fixed set of test recordings after changing this and read the \
                        output yourself.
                        """
                    )
                }
                Section {
                    Button("Restore built-in", role: .destructive) {
                        Task {
                            try? await TemplateStore.shared.resetToBuiltIn(template.meetingType)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(template.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await TemplateStore.shared.save(template)
                            dismiss()
                        }
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
