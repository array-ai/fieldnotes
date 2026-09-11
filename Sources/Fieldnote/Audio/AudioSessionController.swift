#if os(iOS)
import AVFoundation
import Foundation
import OSLog

/// Owns the `AVAudioSession` for recording, and turns the system's interruption and
/// route-change notifications into events the recorder can act on.
///
/// Interruptions are the normal case, not the edge case: a phone call, Siri, or a
/// Bluetooth headset connecting mid-meeting. Each one must leave the audio already
/// captured safely on disk (spec 4.1).
@MainActor
public final class AudioSessionController {

    public enum Event: Sendable {
        case interruptionBegan
        /// `shouldResume` is the system's hint that the app may restart capture.
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: AVAudioSession.RouteChangeReason)
        case mediaServicesReset
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "audio.session")
    private var observers: [NSObjectProtocol] = []
    public var onEvent: (@MainActor (Event) -> Void)?

    public init() {}

    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
        observe()
    }

    public func deactivate() {
        stopObserving()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func observe() {
        stopObserving()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // Notification is not Sendable, so it cannot cross into a main
            // actor-isolated closure. Pull the primitives out here and send only
            // those — they are plain integers.
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonRaw: reasonRaw) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.mediaServicesReset) }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            log.notice("Audio interrupted")
            onEvent?(.interruptionBegan)
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            log.notice("Audio interruption ended, shouldResume=\(shouldResume, privacy: .public)")
            onEvent?(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        onEvent?(.routeChanged(reason: reason))
    }
}
#endif
