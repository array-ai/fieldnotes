import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The four independent payloads, as a menu (spec 6.1).
///
/// Files are built on demand — a PDF or a joined audio file is not worth generating
/// until someone asks for it — so this goes through `UIActivityViewController` rather
/// than `ShareLink`, which wants its payload up front.
struct SharePayloadMenu: View {
    let meeting: MeetingSnapshot
    @State private var sharing: ShareRequest?
    @State private var confirmingAudio: ShareRequest?

    var body: some View {
        ForEach(SharePayload.allCases) { payload in
            Menu(payload.displayName, systemImage: icon(for: payload)) {
                ForEach(payload.formats) { format in
                    Button(format.displayName) {
                        let request = ShareRequest(meeting: meeting, payload: payload, format: format)
                        if payload.warnsBeforeSharing {
                            confirmingAudio = request
                        } else {
                            sharing = request
                        }
                    }
                }
            }
            .disabled(payload != .audio && meeting.state != .complete)
        }
        .sheet(item: $sharing) { request in
            ShareSheet(request: request)
        }
        .alert(item: $confirmingAudio) { request in
            Alert(
                title: Text("Share the raw audio?"),
                message: Text(
                    """
                    This is the rawest form of client data. Once it is in the share \
                    sheet it is out of Fieldnote's control.
                    """
                ),
                primaryButton: .destructive(Text("Share audio")) { sharing = request },
                secondaryButton: .cancel()
            )
        }
    }

    private func icon(for payload: SharePayload) -> String {
        switch payload {
        case .summary: "doc.text"
        case .tasks: "checklist"
        case .transcript: "text.alignleft"
        case .audio: "waveform"
        }
    }
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let meeting: MeetingSnapshot
    let payload: SharePayload
    let format: ShareFormat
}

/// Builds the file, then hands it to the system share sheet.
struct ShareSheet: View {
    let request: ShareRequest
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Could not prepare the file", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if urls.isEmpty {
                ProgressView("Preparing…")
            } else {
                ActivityView(items: urls) { dismiss() }
            }
        }
        .task {
            do {
                let builder = ShareBuilder()
                urls = [try await builder.makeFile(
                    meeting: request.meeting,
                    payload: request.payload,
                    format: request.format
                )]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Composed share with section toggles (spec 6.2).
///
/// The selection is remembered, except audio, which always resets to off.
struct ComposedShareView: View {
    let meeting: MeetingSnapshot
    @Environment(\.dismiss) private var dismiss

    @AppStorage("share.overview") private var overview = true
    @AppStorage("share.decisions") private var decisions = true
    @AppStorage("share.actions") private var actions = true
    @AppStorage("share.questions") private var questions = true
    @AppStorage("share.transcript") private var transcript = false
    @AppStorage("share.format") private var formatRaw = ShareFormat.markdown.rawValue
    @State private var includeAudio = false
    @State private var urls: [URL] = []
    @State private var building = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Include") {
                    Toggle("Overview", isOn: $overview)
                    Toggle("Decisions", isOn: $decisions)
                    Toggle("Action items", isOn: $actions)
                    Toggle("Open questions", isOn: $questions)
                    Toggle("Full transcript", isOn: $transcript)
                }
                Section {
                    Toggle("Attach audio", isOn: $includeAudio)
                } footer: {
                    Text("Audio resets to off every time. It is the rawest form of client data.")
                }
                Section("Format") {
                    Picker("Format", selection: $formatRaw) {
                        Text("Markdown").tag(ShareFormat.markdown.rawValue)
                        Text("Plain text").tag(ShareFormat.plainText.rawValue)
                        Text("Rich text").tag(ShareFormat.richText.rawValue)
                        Text("PDF").tag(ShareFormat.pdf.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Share meeting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") { Task { await build() } }
                        .disabled(building)
                }
            }
            .sheet(isPresented: .constant(!urls.isEmpty)) {
                ActivityView(items: urls) {
                    urls = []
                    dismiss()
                }
            }
        }
    }

    private var sections: MarkdownRenderer.Sections {
        var sections: MarkdownRenderer.Sections = []
        if overview { sections.insert(.overview) }
        if decisions { sections.insert(.decisions) }
        if actions { sections.insert(.actions) }
        if questions { sections.insert(.openQuestions) }
        if transcript { sections.insert(.transcript) }
        return sections
    }

    private func build() async {
        building = true
        defer { building = false }
        let builder = ShareBuilder()
        urls = (try? await builder.makeComposedFiles(
            meeting: meeting,
            sections: sections,
            format: ShareFormat(rawValue: formatRaw) ?? .markdown,
            includeAudio: includeAudio
        )) ?? []
    }
}

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
struct ActivityView: View {
    let items: [Any]
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Ready to share")
            ForEach(items.compactMap { $0 as? URL }, id: \.self) { url in
                ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
            }
            Button("Done", action: onComplete)
        }
        .padding()
    }
}
#endif
