import FieldnoteKit
import Foundation

/// User-editable summary templates (spec 4.5). Built-ins are always present; an edit
/// creates an override stored on disk, and deleting the override restores the
/// built-in. Local JSON, no sync, no server.
public actor TemplateStore {
    public static let shared = TemplateStore()

    private let fileURL: URL
    private var overrides: [MeetingType: SummaryTemplate] = [:]
    private var loaded = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FieldnoteStorage.applicationSupportDirectory
            .appendingPathComponent("templates.json", conformingTo: .json)
    }

    public func template(for type: MeetingType) -> SummaryTemplate {
        loadIfNeeded()
        return overrides[type] ?? PromptTemplates.builtIn(for: type)
    }

    public func save(_ template: SummaryTemplate) throws {
        loadIfNeeded()
        var stored = template
        stored.isBuiltIn = false
        overrides[template.meetingType] = stored
        try persist()
    }

    public func resetToBuiltIn(_ type: MeetingType) throws {
        loadIfNeeded()
        overrides[type] = nil
        try persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SummaryTemplate].self, from: data) else { return }
        overrides = Dictionary(decoded.map { ($0.meetingType, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(overrides.values))
        try FieldnoteStorage.ensureDirectory(fileURL.deletingLastPathComponent())
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
