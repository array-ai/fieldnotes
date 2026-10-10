import FieldnoteKit
import SwiftUI

/// Settings → Acknowledgements: the models, data and libraries Fieldnote is built
/// from, each with its credit and full licence text (see `Acknowledgement`).
struct AcknowledgementsView: View {
    var body: some View {
        List {
            ForEach(Acknowledgement.Kind.allCases, id: \.self) { kind in
                Section(kind.rawValue) {
                    ForEach(Acknowledgement.all.filter { $0.kind == kind }) { entry in
                        NavigationLink {
                            AcknowledgementDetail(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.licence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementDetail: View {
    let entry: Acknowledgement

    var body: some View {
        List {
            Section {
                Text(entry.credit)
                LabeledContent("Licence", value: entry.licence)
                Link(destination: entry.source) {
                    Label(entry.source.host() ?? "Source", systemImage: "arrow.up.right.square")
                }
            }
            if let notice = entry.noticeFile.flatMap(Self.text) {
                Section("Notice") { licenceText(notice) }
            }
            Section("Licence") {
                licenceText(Self.text(entry.licenceFile) ?? "The licence text is missing from this build.")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenceText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
    }

    /// A file from the app bundle's `Licenses` folder (xtool.yml resources).
    private static func text(_ file: String) -> String? {
        guard let url = Bundle.main.resourceURL?.appending(path: "\(Acknowledgement.folder)/\(file)") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
