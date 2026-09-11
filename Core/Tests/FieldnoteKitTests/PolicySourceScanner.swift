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

    /// Repo root, found by walking up from this file until `xtool.yml` appears.
    ///
    /// Walking beats counting directories. Counting broke the first time the package
    /// was split for xtool — the root landed on `Core/`, the scan found no files, and
    /// four policy tests went green on an empty set. A rule that passes because it
    /// scanned nothing is worse than one that fails, so `scannerSeesTheAppSources`
    /// and `scannerDetectsWhatIsThere` below exist to make that impossible to repeat.
    static let repositoryRoot: URL = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = directory.appending(path: "xtool.yml").path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: marker) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate the repository root from \(#filePath)")
    }()

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

    /// Repo-relative, with no leading slash: `Sources/Fieldnote/...`.
    ///
    /// Normalised rather than left to chance, because whether the root's path carries
    /// a trailing slash is a Foundation detail, and every exclusion and expectation in
    /// the policy suite compares these strings.
    static func relativePath(_ url: URL) -> String {
        let root = repositoryRoot.path(percentEncoded: false)
        var path = url.path(percentEncoded: false)
        if path.hasPrefix(root) { path.removeFirst(root.count) }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
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
