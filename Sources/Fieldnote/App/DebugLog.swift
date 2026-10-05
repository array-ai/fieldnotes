import Foundation

/// A plain-text activity log the user can read in Settings → Debug: what ran, for
/// how long, and what failed.
///
/// `OSLogStore` only sees the current process, and processing often runs in a
/// background task long after the screen that started it is gone, so this writes its
/// own file. It records metadata only — stage names, durations, counts, short meeting
/// IDs and error text. Never transcript text or titles: the log is meant to be shared.
///
/// Writes go through a serial queue and one long-lived file handle. The pipeline
/// runs with the phone locked, and a file under complete protection can't be
/// reopened then, so the file uses `completeUntilFirstUserAuthentication` and stays
/// open.
public final class DebugLog: @unchecked Sendable {

    public static let shared = DebugLog()

    public let fileURL: URL
    private let queue = DispatchQueue(label: "fieldnote.debuglog")
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 512 * 1024
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(fileURL: URL = FieldnoteStorage.applicationSupportDirectory.appendingPathComponent("debug.log")) {
        self.fileURL = fileURL
    }

    /// Fire and forget. Safe from any thread or actor.
    public func log(_ category: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            append("\(formatter.string(from: now)) [\(category)] \(message)\n")
        }
    }

    /// The whole log, oldest first.
    public func contents() -> String {
        queue.sync {
            try? handle?.synchronize()
            return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    public func clear() {
        queue.sync {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Build

    /// "0.1.0 (23, 24fff48)": marketing version, build number, and the git commit
    /// CI stamped in at release ("local" for a developer build).
    public static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["FieldnoteGitCommit"] as? String ?? "local"
        return "\(version) (\(build), \(commit))"
    }

    /// Logged once per launch, so every stretch of the log says what produced it.
    public func logLaunch(device: String) {
        log("app", "launched Fieldnote \(Self.appVersion) on \(device), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    // MARK: - Formatting helpers

    /// "1.23s" from a start instant.
    public static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }

    /// An error as its kind and code only, for errors whose description can carry a
    /// file name or other user text (an imported file's name is often a meeting
    /// title).
    public static func kind(of error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// The first 8 characters of a meeting ID: enough to tell meetings apart in the
    /// log without the log identifying anything.
    public static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    // MARK: - File

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try openHandle()
            try handle.write(contentsOf: data)
            if try handle.offset() > maxBytes { try trim() }
        } catch {
            // Logging must never take the app down. Drop the line.
            try? handle?.close()
            handle = nil
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            try FieldnoteStorage.ensureDirectory(fileURL.deletingLastPathComponent())
            manager.createFile(
                atPath: fileURL.path(percentEncoded: false),
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        try opened.seekToEnd()
        handle = opened
        return opened
    }

    /// Keeps the newest half once the file passes `maxBytes`.
    private func trim() throws {
        try handle?.close()
        handle = nil
        let data = try Data(contentsOf: fileURL)
        var tail = data.suffix(Int(maxBytes / 2))
        // Start on a line boundary.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try Data(tail).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path(percentEncoded: false)
        )
    }
}
