import CryptoKit
import FieldnoteKit
import FluidAudio
import Foundation
import Observation

/// Downloads the optional models (`ModelPack.catalog`) when the user asks, and
/// nothing else.
///
/// This is the only file in the app allowed to make a network request for a model
/// (the policy checks enforce it). Every request goes to a pinned Hugging Face
/// revision, and every file is checked against its SHA-256 from the committed
/// manifest before the pack counts as installed:
///
/// - Files land in a staging folder first; the pack is moved into place and marked
///   installed only when every file has verified, so a cut-off download never
///   half-works.
/// - A retry skips files that already verified, so it resumes rather than restarts.
/// - Packs live in Application Support (not Caches, which iOS purges), excluded from
///   backup, and readable while the phone is locked — processing runs locked.
@MainActor
@Observable
public final class ModelDownloads {

    public static let shared = ModelDownloads()

    public enum State: Equatable, Sendable {
        case notInstalled
        case downloading(Double)
        /// Downloaded and verified; compiling for this phone's Neural Engine once.
        case preparing
        case installed
        case failed(String)
    }

    public private(set) var states: [ModelPack.ID: State] = [:]
    private var tasks: [ModelPack.ID: Task<Void, Never>] = [:]

    private init() {
        for id in ModelPack.ID.allCases {
            states[id] = Self.installedDirectory(for: id) == nil ? .notInstalled : .installed
        }
    }

    public func state(_ id: ModelPack.ID) -> State { states[id] ?? .notInstalled }

    public func isInstalled(_ id: ModelPack.ID) -> Bool { state(id) == .installed }

    // MARK: - Where packs live

    nonisolated static var root: URL {
        FieldnoteStorage.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func directory(for id: ModelPack.ID) -> URL {
        root.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    nonisolated private static func markerURL(for id: ModelPack.ID) -> URL {
        directory(for: id).appendingPathComponent(".installed")
    }

    /// The pack's folder if it is fully downloaded and verified at the current
    /// pinned revision; nil otherwise. Safe to call from any actor.
    nonisolated public static func installedDirectory(for id: ModelPack.ID) -> URL? {
        guard let marker = try? String(contentsOf: markerURL(for: id), encoding: .utf8),
              marker.trimmingCharacters(in: .whitespacesAndNewlines) == ModelPack.pack(id).revision else { return nil }
        return directory(for: id)
    }

    // MARK: - Actions

    public func download(_ id: ModelPack.ID) {
        guard tasks[id] == nil else { return }
        states[id] = .downloading(0)
        tasks[id] = Task {
            do {
                // Off the main actor: hashing and the first model compile take seconds
                // to minutes and must not freeze the UI.
                try await Self.install(ModelPack.pack(id)) { state in
                    Task { @MainActor in ModelDownloads.shared.states[id] = state }
                }
                states[id] = .installed
                DebugLog.shared.log("models", "\(id.rawValue): installed")
            } catch is CancellationError {
                states[id] = .notInstalled
                DebugLog.shared.log("models", "\(id.rawValue): download cancelled")
            } catch {
                states[id] = .failed(error.localizedDescription)
                DebugLog.shared.log("models", "\(id.rawValue): download failed: \(error)")
            }
            tasks[id] = nil
        }
    }

    public func cancel(_ id: ModelPack.ID) {
        tasks[id]?.cancel()
    }

    public func delete(_ id: ModelPack.ID) {
        cancel(id)
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        try? FileManager.default.removeItem(at: Self.staging(for: id))
        states[id] = .notInstalled
        DebugLog.shared.log("models", "\(id.rawValue): deleted")
    }

    // MARK: - Install

    nonisolated private static func staging(for id: ModelPack.ID) -> URL {
        root.appendingPathComponent(id.rawValue + ".partial", isDirectory: true)
    }

    nonisolated private static func install(
        _ pack: ModelPack,
        report: @escaping @Sendable (State) -> Void
    ) async throws {
        let manager = FileManager.default
        let staging = Self.staging(for: pack.id)
        try FieldnoteStorage.ensureDirectory(Self.root)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.checkFreeSpace(for: pack, at: Self.root)

        let started = ContinuousClock.now
        DebugLog.shared.log("models", "\(pack.id.rawValue): downloading \(pack.totalBytes.byteCountDescription) from \(pack.repo)@\(pack.revision.prefix(7))")
        var done: Int64 = 0
        for file in pack.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            if manager.fileExists(atPath: target.path), (try? Self.sha256(of: target)) == file.sha256 {
                done += file.size
                continue
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let total = pack.totalBytes
            let progress = DownloadProgress { written in
                report(.downloading(Double(base + written) / Double(max(total, 1))))
            }
            let (temporary, response) = try await URLSession.shared.download(from: pack.url(for: file), delegate: progress)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? manager.removeItem(at: temporary)
                throw DownloadError.server(file.path)
            }
            try? manager.removeItem(at: target)
            try manager.moveItem(at: temporary, to: target)
            guard try Self.sha256(of: target) == file.sha256 else {
                try? manager.removeItem(at: target)
                throw DownloadError.checksum(file.path)
            }
            done += file.size
            report(.downloading(Double(done) / Double(max(pack.totalBytes, 1))))
        }

        // Every file verified: move into place, then mark installed last.
        let final = Self.directory(for: pack.id)
        try? manager.removeItem(at: final)
        try manager.moveItem(at: staging, to: final)
        try Self.prepareForLockedUse(final)

        // Compile once now, while the user is watching. Parakeet's first Neural Engine
        // compile can take minutes; done inside a background task it would be cut off
        // and redone every time. CoreML caches the result for later loads.
        if let version = ParakeetTranscriber.version(for: pack.id) {
            report(.preparing)
            let compileStarted = ContinuousClock.now
            _ = try AsrModels.loadLocal(from: final, version: version)
            DebugLog.shared.log("models", "\(pack.id.rawValue): first compile took \(DebugLog.elapsed(since: compileStarted))")
        }
        try pack.revision.write(to: Self.markerURL(for: pack.id), atomically: true, encoding: .utf8)
        DebugLog.shared.log("models", "\(pack.id.rawValue): \(pack.files.count) files verified in \(DebugLog.elapsed(since: started))")
    }

    nonisolated private static func checkFreeSpace(for pack: ModelPack, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < pack.totalBytes + 200_000_000 {
            throw DownloadError.space(pack.totalBytes)
        }
    }

    /// Excluded from backup (re-downloadable), and openable while the phone is locked.
    nonisolated private static func prepareForLockedUse(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try manager.setAttributes(attributes, ofItemAtPath: directory.path)
        if let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                try? manager.setAttributes(attributes, ofItemAtPath: item.path)
            }
        }
    }

    /// Streams the file through SHA-256 in 4 MB reads: weights are hundreds of MB.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public enum DownloadError: Error, LocalizedError {
        case server(String)
        case checksum(String)
        case space(Int64)

        public var errorDescription: String? {
            switch self {
            case .server(let path): "The server didn't return \(path)."
            case .checksum(let path): "\(path) didn't match its published checksum, so it was discarded."
            case .space(let bytes): "Not enough free space: this needs \(bytes.byteCountDescription) plus some room to spare."
            }
        }
    }
}

/// Reports bytes written for one file download.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onWrite: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var reported: Int64 = 0

    init(onWrite: @escaping @Sendable (Int64) -> Void) {
        self.onWrite = onWrite
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Every couple of MB is plenty for a progress bar.
        lock.lock()
        let due = totalBytesWritten - reported >= 2_000_000
        if due { reported = totalBytesWritten }
        lock.unlock()
        if due { onWrite(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
