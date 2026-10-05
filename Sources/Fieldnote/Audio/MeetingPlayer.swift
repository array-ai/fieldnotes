import AVFoundation
import FieldnoteKit
import Foundation
import Observation

/// Plays a meeting's recording on the meeting screen.
///
/// The audio is on disk as five-minute chunks (a durability choice, see
/// `ChunkedAudioWriter`), so they're joined into one composition here — the same
/// way `AudioExporter` joins them for sharing — and played as a single track. That
/// keeps seeking and the clock in recording time, which is what transcript
/// timestamps use.
@MainActor
@Observable
public final class MeetingPlayer {

    public private(set) var isReady = false
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var failure: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    public static let rates: [Float] = [1, 1.5, 2]

    public init() {}

    public func load(meetingID: UUID) async {
        guard player == nil else { return }
        let chunks = ChunkedAudioWriter.existingChunks(in: FieldnoteStorage.audioChunkDirectory(for: meetingID))
            .sorted { $0.index < $1.index }
        guard !chunks.isEmpty else {
            failure = "No audio is stored for this meeting."
            return
        }
        do {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw AudioExporter.ExportError.compositionFailed }

            var cursor = CMTime.zero
            for chunk in chunks {
                let asset = AVURLAsset(url: chunk.url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let length = try await asset.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: cursor)
                cursor = cursor + length
            }

            let item = AVPlayerItem(asset: composition)
            let player = AVPlayer(playerItem: item)
            self.player = player
            duration = cursor.seconds.isFinite ? cursor.seconds : 0
            observe(player, item: item)
            isReady = true
        } catch {
            failure = "The recording couldn't be opened: \(error.localizedDescription)"
            DebugLog.shared.log("player", "couldn't load audio: \(error)")
        }
    }

    public func togglePlay() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard let player else { return }
        #if os(iOS)
        // Plain playback: the recorder sets its own session when it starts.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if duration > 0, currentTime >= duration - 0.25 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Jumps to a line and plays from there.
    public func play(from time: TimeInterval) {
        seek(to: time)
        play()
    }

    public func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    public func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        if isPlaying { player?.rate = rate }
    }

    /// Call when the screen goes away.
    public func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        isReady = false
    }

    private func observe(_ player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }
}
