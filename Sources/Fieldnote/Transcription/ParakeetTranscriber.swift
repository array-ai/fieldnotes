import AVFoundation
import FieldnoteKit
import FluidAudio
import Foundation

/// Transcribes a finished recording with one of NVIDIA's Parakeet models (v3
/// multilingual, v2 English, TDT-CTC 110M English), when the user has downloaded it
/// and chosen it in Settings.
///
/// Runs after stop, never during recording (Apple's model does the live text, and
/// Nemotron may be running live). It reads the meeting's 16 kHz speaker buffer —
/// the same timeline speaker identification uses — through a temporary WAV, so
/// FluidAudio's disk-backed long-recording path handles chunking and seams.
/// Models load per run and are released afterwards: Parakeet, Nemotron and the
/// summary model together are too much to keep resident in a background task.
public enum ParakeetTranscriber {

    public enum Failure: Error, LocalizedError {
        case notDownloaded
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .notDownloaded: "Parakeet isn't downloaded."
            case .noAudio: "There's no audio to transcribe."
            }
        }
    }

    /// The Parakeet model the next transcript for `localeIdentifier` would use: the
    /// one chosen in Settings, if it's downloaded and handles the language.
    public static func selectedEngine(for localeIdentifier: String) -> TranscriptionEngine? {
        let engine = TranscriptionEngine(storedValue: UserDefaults.standard.string(forKey: TranscriptionEngine.defaultsKey))
        guard !engine.runsLive, let pack = engine.modelPack,
              ModelDownloads.installedDirectory(for: pack) != nil,
              engine.supports(localeIdentifier) else { return nil }
        return engine
    }

    public static func isSelected(for localeIdentifier: String) -> Bool {
        selectedEngine(for: localeIdentifier) != nil
    }

    /// FluidAudio's model version for each downloadable pack.
    static func version(for pack: ModelPack.ID) -> AsrModelVersion? {
        switch pack {
        case .parakeetV3: .v3
        case .parakeetV2: .v2
        case .parakeetTdtCtc110m: .tdtCtc110m
        case .parakeetCtcWords, .pyannoteCommunity1, .nemotronStreaming,
             .minicpm5, .minicpm5H17g, .minicpm5H17p, .minicpm5H18p, .minicpm5_2b, .minicpm5_2bH17p, .qwen3_5_2b, .qwen3_5_2bH17p, .lfm2_5, .lfm2_5H17p: nil
        }
    }

    public static func transcribe(
        engine: TranscriptionEngine,
        meetingID: UUID,
        localeIdentifier: String,
        maxSeconds: Double? = nil,
        fixWords: Bool = true,
        progress: @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let pack = engine.modelPack, let version = version(for: pack),
              let directory = ModelDownloads.installedDirectory(for: pack) else { throw Failure.notDownloaded }
        let debug = DebugLog.shared
        let id = DebugLog.short(meetingID)

        let loadStarted = ContinuousClock.now
        let models = try AsrModels.loadLocal(from: directory, version: version)
        let manager = AsrManager(config: .default, models: models)
        debug.log("transcript", "\(id): \(engine.rawValue) loaded in \(DebugLog.elapsed(since: loadStarted))")
        progress(0.1)

        let wav = try writeWAV(meetingID: meetingID, maxSeconds: maxSeconds)
        defer { try? FileManager.default.removeItem(at: wav.url) }
        guard wav.seconds > 0.5 else { throw Failure.noAudio }
        progress(0.2)

        let runStarted = ContinuousClock.now
        // Shaped for this model: TDT-CTC 110M has one decoder layer, v2/v3 two. The
        // default (two) failed on 110M for short recordings with "MultiArray shape
        // (2 x 1 x 640) does not match (1 x 1 x 640)" (build 40).
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // Only the multilingual model takes a language hint.
        let language = version == .v3 ? Language(rawValue: String(localeIdentifier.prefix(2)).lowercased()) : nil
        let result = try await manager.transcribe(wav.url, decoderState: &state, language: language)
        let tokenTimings = result.tokenTimings ?? []
        let words = WordFixer.words(from: tokenTimings)
        let elapsed = runStarted.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        debug.log(
            "transcript",
            String(format: "%@: %@ transcribed %.0f s in %.1f s (%.0f× real time), %d words",
                   id, engine.rawValue, wav.seconds, seconds, wav.seconds / max(seconds, 0.001), words.count)
        )
        // Parakeet's models go before the word fixer's load.
        await manager.cleanup()
        progress(0.9)

        let fixed = fixWords ? await WordFixer.fix(tokenTimings, meetingID: meetingID, localeIdentifier: localeIdentifier) ?? words : words
        let lines = WordLines.lines(from: fixed)
        debug.log("transcript", "\(id): \(lines.count) lines")
        progress(1)
        return lines
    }

    /// The speaker buffer (raw Float32, 16 kHz mono) as a WAV FluidAudio can read
    /// from disk, written in slices so a long meeting never sits in memory whole.
    /// `maxSeconds` keeps only the start (the benchmark).
    private static func writeWAV(meetingID: UUID, maxSeconds: Double? = nil) throws -> (url: URL, seconds: Double) {
        let source = FieldnoteStorage.meetingDirectory(for: meetingID).appendingPathComponent("diarization.f32")
        guard let input = FileHandle(forReadingAtPath: source.path) else { throw Failure.noAudio }
        defer { try? input.close() }

        let format = AudioFormats.diarization
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(meetingID.uuidString).wav")
        try? FileManager.default.removeItem(at: url)
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let slice = 16_000 * 30
        let limit = maxSeconds.map { Int($0 * 16_000) } ?? .max
        var frames = 0
        // Each slice is freed before the next: without the pool every read stayed in
        // memory until the end, the whole meeting after all.
        while try autoreleasepool(invoking: {
            let wanted = min(slice, limit - frames)
            guard wanted > 0,
                  let data = try input.read(upToCount: wanted * MemoryLayout<Float>.size), !data.isEmpty else { return false }
            let count = data.count / MemoryLayout<Float>.size
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return false }
            data.withUnsafeBytes { raw in
                channel.update(from: raw.bindMemory(to: Float.self).baseAddress!, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try output.write(from: buffer)
            frames += count
            return true
        }) {}
        return (url, Double(frames) / 16_000)
    }
}
