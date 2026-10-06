import CryptoKit
import FieldnoteKit
import FluidAudio
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

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
/// - Files come through a background `URLSession` (`BackgroundDownloader`): the system
///   keeps downloading while the phone is locked or the app is closed, and a dropped
///   connection resumes from where it stopped instead of starting the file again.
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
        defer { UserDefaults.standard.removeObject(forKey: Self.preparingKey) }
        Self.removeRetiredPacks()
        for id in ModelPack.ID.allCases {
            if Self.installedDirectory(for: id) != nil {
                states[id] = .installed
            } else if Self.closedWhilePreparing(id),
                      UserDefaults.standard.string(forKey: Self.preparingKey) == id.rawValue {
                // The app was closed part-way through the first compile: almost
                // always iOS closing it for memory (build 37: Qwen3 1.7B took 2.4 GB).
                states[id] = .failed("Fieldnote closed while preparing this model, most likely out of memory. The download is kept; tap Download to try again.")
                DebugLog.shared.log("models", "\(id.rawValue): the app closed while preparing it (most likely out of memory)")
            } else if FileManager.default.fileExists(atPath: Self.staging(for: id).path)
                        || Self.closedWhilePreparing(id) {
                // Started before the app was last closed (downloading, or preparing
                // after the download); finished files are kept.
                states[id] = .failed("Interrupted. Tap Download to carry on where it stopped.")
            } else {
                states[id] = .notInstalled
            }
        }
    }

    /// Deletes downloads of models the app no longer offers (Qwen3 1.7B: 1.4 GB),
    /// finished or part-way.
    nonisolated private static func removeRetiredPacks() {
        let manager = FileManager.default
        let known = Set(ModelPack.ID.allCases.map(\.rawValue))
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let id = folder.lastPathComponent.replacingOccurrences(of: ".partial", with: "")
            guard !known.contains(id) else { continue }
            try? manager.removeItem(at: folder)
            DebugLog.shared.log("models", "\(id): no longer offered; removed its files")
        }
    }

    /// The pack whose first compile is running, so a launch after a kill can say so.
    nonisolated private static let preparingKey = "modelDownloads.preparing"

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

    /// Files moved into place but never marked installed: the app closed while the
    /// model was preparing. (A folder marked with an older revision is an old
    /// install, not this.)
    nonisolated private static func closedWhilePreparing(_ id: ModelPack.ID) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory(for: id).path)
            && !manager.fileExists(atPath: markerURL(for: id).path)
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
                    Task { @MainActor in
                        ModelDownloads.shared.states[id] = state
                        // The first compile only runs while the app is open; a
                        // screen lock would suspend it part-way.
                        ModelDownloads.shared.updateScreenLock()
                    }
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
            updateScreenLock()
            tasks[id] = nil
        }
    }

    /// The screen stays on while any model prepares, whatever else finishes.
    private func updateScreenLock() {
        #if os(iOS)
        ScreenAwake.set(.preparingModel, states.values.contains(.preparing))
        #endif
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
        // Closed while preparing: the files were already moved into place. Move them
        // back so they're checked and kept rather than downloaded again.
        let final = Self.directory(for: pack.id)
        if Self.closedWhilePreparing(pack.id), !manager.fileExists(atPath: staging.path) {
            try manager.moveItem(at: final, to: staging)
        }
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
            try await Self.fetch(pack.url(for: file), to: target, name: file.path) { written in
                report(.downloading(Double(base + written) / Double(max(total, 1))))
            }
            guard try Self.sha256(of: target) == file.sha256 else {
                try? manager.removeItem(at: target)
                throw DownloadError.checksum(file.path)
            }
            done += file.size
            report(.downloading(Double(done) / Double(max(pack.totalBytes, 1))))
        }

        // Every file verified: move into place, then mark installed last.
        try? manager.removeItem(at: final)
        try manager.moveItem(at: staging, to: final)
        try Self.prepareForLockedUse(final)
        UserDefaults.standard.set(pack.id.rawValue, forKey: Self.preparingKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.preparingKey) }

        // Preparing loads the model into memory: one heavy job at a time.
        let prepares = ParakeetTranscriber.version(for: pack.id) != nil
            || pack.id == .nemotronStreaming
            || pack.id.rawValue.hasPrefix(ModelPack.ID.minicpm5.rawValue)
        if prepares {
            report(.preparing)
            await HeavyModelWork.shared.acquire("preparing \(pack.id.rawValue)")
        }
        do {
            // Compile once now, while the user is watching. Parakeet's first Neural Engine
            // compile can take minutes; done inside a background task it would be cut off
            // and redone every time. CoreML caches the result for later loads.
            if let version = ParakeetTranscriber.version(for: pack.id) {
                report(.preparing)
                let compileStarted = ContinuousClock.now
                _ = try AsrModels.loadLocal(from: final, version: version)
                DebugLog.shared.log("models", "\(pack.id.rawValue): first compile took \(DebugLog.elapsed(since: compileStarted))")
            }
            if pack.id == .nemotronStreaming {
                report(.preparing)
                let compileStarted = ContinuousClock.now
                _ = try await StreamingNemotronMultilingualAsrManager.preloadShared(
                    from: final.appendingPathComponent(NemotronStreamingTranscriber.variantPath, isDirectory: true)
                )
                DebugLog.shared.log("models", "nemotronStreaming: first compile took \(DebugLog.elapsed(since: compileStarted))")
            }
            if pack.id.rawValue.hasPrefix(ModelPack.ID.minicpm5.rawValue) {
                // Core AI compiles the portable model for this phone on first load.
                report(.preparing)
                // Two big compiles at once (after an update, the speaker model rebuilds
                // at launch) is how the app ran out of memory. One at a time.
                let waitStarted = ContinuousClock.now
                await DiarizationService.shared.waitForWarmUp()
                if waitStarted.duration(to: .now) > .seconds(1) {
                    DebugLog.shared.log("models", "\(pack.id.rawValue): waited \(DebugLog.elapsed(since: waitStarted)) for the speaker model to finish loading")
                }
                let compileStarted = ContinuousClock.now
                #if os(iOS)
                DebugLog.shared.log("models", "\(pack.id.rawValue): preparing, \(CrashWatch.memoryLeft) memory left")
                #endif
                let model = try await OnDeviceModel.loadLocalModel(
                    at: pack.bundleFolder.map { final.appendingPathComponent($0, isDirectory: true) } ?? final,
                    eager: true
                )
                model.unload()
                #if os(iOS)
                DebugLog.shared.log("models", "\(pack.id.rawValue): \(CrashWatch.memoryLeft) memory left after preparing")
                #endif
                DebugLog.shared.log("models", "\(pack.id.rawValue): first compile took \(DebugLog.elapsed(since: compileStarted))")
            }
        } catch {
            if prepares { await HeavyModelWork.shared.release() }
            throw error
        }
        if prepares { await HeavyModelWork.shared.release() }
        try pack.revision.write(to: Self.markerURL(for: pack.id), atomically: true, encoding: .utf8)
        DebugLog.shared.log("models", "\(pack.id.rawValue): \(pack.files.count) files verified in \(DebugLog.elapsed(since: started))")
    }

    /// One file, retried when the connection drops. Each retry resumes from the bytes
    /// already received; the background session also waits out a lost connection.
    nonisolated private static func fetch(
        _ url: URL,
        to target: URL,
        name: String,
        onWrite: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await BackgroundDownloader.shared.download(url, to: target, onWrite: onWrite)
                return
            } catch let error as URLError where attempt < 5 && Self.isTransient(error) {
                attempt += 1
                DebugLog.shared.log("models", "\(name): connection dropped (\(error.code.rawValue)); resuming, attempt \(attempt + 1)")
                try await Task.sleep(for: .seconds(Double(attempt * attempt) * 2))
            } catch BackgroundDownloader.Failure.status(let code) where attempt < 5 && code != 404 {
                // A resumed request whose signed CDN link expired: start the file over.
                attempt += 1
                BackgroundDownloader.discardResumeData(for: target)
                DebugLog.shared.log("models", "\(name): server answered \(code); restarting the file, attempt \(attempt + 1)")
            } catch BackgroundDownloader.Failure.status {
                throw DownloadError.server(name)
            }
        }
    }

    nonisolated private static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
         .dnsLookupFailed, .cannotFindHost, .backgroundSessionWasDisconnected].contains(error.code)
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
        // Each read is released before the next: without the pool, hashing a 1.4 GB
        // file kept every chunk alive until the end and iOS closed the app.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
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

/// The model files' background `URLSession`.
///
/// A background session is run by the system, not the app: downloads carry on while
/// the phone is locked or the app is suspended or closed, and a request that fails
/// mid-file leaves resume data so the next attempt picks up where it stopped.
///
/// Each task carries its destination in `taskDescription` and the delegate moves the
/// finished file there itself, so a file that completes while the app isn't running
/// is still kept: the next Download tap verifies it and moves on to the next file.
final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloader()
    static let identifier = "com.publicarray.fieldnotes.models"

    enum Failure: Error {
        case status(Int)
    }

    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    private var progress: [Int: @Sendable (Int64) -> Void] = [:]
    private var reported: [Int: Int64] = [:]
    private var failures: [Int: Error] = [:]
    private var systemCompletion: (() -> Void)?

    /// Created at launch (`ModelDownloadsAppDelegate`) so events for downloads that
    /// finished while the app was closed are delivered.
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 24 * 3_600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    static func resumeDataURL(for target: URL) -> URL {
        target.appendingPathExtension("resume")
    }

    static func discardResumeData(for target: URL) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: target))
    }

    func download(_ url: URL, to target: URL, onWrite: @escaping @Sendable (Int64) -> Void) async throws {
        // Still running from before the app was closed: wait for it rather than start
        // a second copy.
        let running = await session.allTasks.first {
            $0.taskDescription == target.path && ($0.state == .running || $0.state == .suspended)
        } as? URLSessionDownloadTask
        let task: URLSessionDownloadTask
        if let running {
            task = running
        } else if let data = try? Data(contentsOf: Self.resumeDataURL(for: target)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        Self.discardResumeData(for: target)
        task.taskDescription = target.path

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                waiting[task.taskIdentifier] = continuation
                progress[task.taskIdentifier] = onWrite
                lock.unlock()
                task.resume()
                // A reattached task can finish before it was registered above.
                if task.state == .completed {
                    lock.lock()
                    let pending = waiting.removeValue(forKey: task.taskIdentifier)
                    lock.unlock()
                    if FileManager.default.fileExists(atPath: target.path) {
                        pending?.resume()
                    } else {
                        pending?.resume(throwing: URLError(.networkConnectionLost))
                    }
                }
            }
        } onCancel: {
            task.cancel { data in
                if let data { try? data.write(to: Self.resumeDataURL(for: target)) }
            }
        }
    }

    func handleSystemEvents(completion: @escaping () -> Void) {
        lock.lock()
        systemCompletion = completion
        lock.unlock()
        _ = session
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Every couple of MB is plenty for a progress bar.
        lock.lock()
        let id = downloadTask.taskIdentifier
        let due = totalBytesWritten - (reported[id] ?? 0) >= 2_000_000
        if due { reported[id] = totalBytesWritten }
        let onWrite = progress[id]
        lock.unlock()
        if due { onWrite?(totalBytesWritten) }
    }

    /// The file must be moved before this returns: the system deletes it afterwards.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var failure: Error?
        if status == 200 || status == 206, let path = downloadTask.taskDescription {
            let target = URL(fileURLWithPath: path)
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? manager.removeItem(at: target)
                try manager.moveItem(at: location, to: target)
            } catch {
                failure = error
            }
        } else {
            failure = Failure.status(status)
        }
        if let failure {
            lock.lock()
            failures[downloadTask.taskIdentifier] = failure
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError,
           let data = error.downloadTaskResumeData,
           let path = task.taskDescription {
            try? data.write(to: Self.resumeDataURL(for: URL(fileURLWithPath: path)))
        }
        lock.lock()
        let id = task.taskIdentifier
        let continuation = waiting.removeValue(forKey: id)
        let failure = failures.removeValue(forKey: id)
        progress[id] = nil
        reported[id] = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = systemCompletion
        systemCompletion = nil
        lock.unlock()
        // The system's handler: called once, on the main queue, as UIKit requires.
        nonisolated(unsafe) let handler = completion
        if handler != nil { DispatchQueue.main.async { handler?() } }
    }
}

#if os(iOS)
/// Only here for the model downloads' background session (this file is the one
/// allowed to touch `URLSession`).
final class ModelDownloadsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Reconnects to downloads that carried on while the app was closed. No
        // request is made unless one was already under way.
        _ = BackgroundDownloader.shared.session
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloader.identifier else { return completionHandler() }
        BackgroundDownloader.shared.handleSystemEvents(completion: completionHandler)
    }
}
#endif
