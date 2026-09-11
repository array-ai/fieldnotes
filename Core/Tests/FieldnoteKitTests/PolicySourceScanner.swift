import Foundation

/// Reads the checked-in app sources so the policy tests can assert on them.
///
/// Source scanning rather than runtime assertion because the rules being enforced are
/// "this code does not exist" rules — an App Intent that is never invoked still puts
/// meeting content in the Spotlight semantic index, and a session constructed on an
/// unpinned model still routes off-device the first time that branch runs in
/// production (spec constraints 6-8).
enum PolicySourceScanner {

    struct SourceFile {
        var path: String
        var contents: String
    }

    /// Repo root, derived from this file's own location.
    static var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()   // FieldnoteTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Every Swift file shipped in the app and the widget extension. Test sources are
    /// deliberately excluded: they name the forbidden symbols in order to forbid them.
    static func appSources() -> [SourceFile] {
        ["Sources/Fieldnote", "Sources/FieldnoteShared", "Sources/FieldnoteWidgets"]
            .map { repositoryRoot.appending(path: $0) }
            .flatMap(swiftFiles(in:))
            .compactMap { url in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return SourceFile(path: relativePath(url), contents: contents)
            }
    }

    static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func relativePath(_ url: URL) -> String {
        url.path(percentEncoded: false)
            .replacingOccurrences(of: repositoryRoot.path(percentEncoded: false), with: "")
    }

    /// Files containing `needle`, ignoring comment lines so a rule can be *described*
    /// in a doc comment without tripping itself.
    static func filesContaining(_ needle: String, excluding allowed: Set<String> = []) -> [String] {
        appSources().compactMap { file in
            guard !allowed.contains(file.path) else { return nil }
            let hit = file.contents
                .components(separatedBy: .newlines)
                .contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"), !trimmed.hasPrefix("*") else { return false }
                    return line.contains(needle)
                }
            return hit ? file.path : nil
        }
    }
}
