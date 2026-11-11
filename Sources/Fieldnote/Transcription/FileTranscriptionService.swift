import AVFoundation
import FieldnoteKit
import Foundation
import OSLog

/// Transcribes a recording from the audio chunks on disk.
///
/// This is the recovery path and the import path in one. It runs when a live
/// transcript is missing or short — app killed mid-meeting, transcription started
/// late, or a file imported from a dedicated recorder (spec, phase 4) — and it is
/// what makes the transcribing stage resumable: chunks already transcribed are
/// skipped on a retry.
public actor FileTranscriptionService {

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "speech.file")
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en_AU")) {
        self.locale = locale
    }

    /// - Parameters:
    ///   - fromChunkIndex: first chunk to process. A resumed run starts where the
    ///     checkpoint left off rather than re-transcribing an hour of audio.
    ///   - progress: 0...1 across the chunks actually processed.
    public func transcribe(
        chunks: [ChunkedAudioWriter.Chunk],
        fromChunkIndex: Int = 0,
        progress: @Sendable (Double, Int) -> Void = { _, _ in }
    ) async throws -> [TranscriptSegment] {
        let pending = chunks.filter { $0.index >= fromChunkIndex }
        guard !pending.isEmpty else { return [] }

        var all: [TranscriptSegment] = []
        for (position, chunk) in pending.enumerated() {
            try Task.checkCancellation()
            // A chunk cut off by the app closing mid-recording can't be opened. Skip
            // it rather than fail the whole meeting (and every Try again after).
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: chunk.url)
            } catch {
                // Locked phone: the chunk is fine, just sealed. Stop and wait for the
                // unlock rather than save a transcript with a hole in it.
                let unlocked = await PowerState.isProtectedDataAvailable()
                if PhoneLocked.isCause(error) || !unlocked {
                    DebugLog.shared.log("transcript", "audio chunk \(chunk.index + 1) of \(chunks.count) is sealed (phone locked); stopping until it's unlocked")
                    throw PhoneLocked()
                }
                DebugLog.shared.log("transcript", "audio chunk \(chunk.index + 1) of \(chunks.count) can't be read; skipping it (\(error.localizedDescription))")
                progress(Double(position + 1) / Double(pending.count), chunk.index)
                continue
            }
            let session = TranscriptionSession(locale: locale, timeOffset: chunk.startTime)
            try await session.start()
            do {
                try await feed(file, into: session)
            } catch is CancellationError {
                await session.cancel()
                throw CancellationError()
            } catch {
                // A chunk that breaks part-way: keep what was heard up to there.
                DebugLog.shared.log("transcript", "audio chunk \(chunk.index + 1) of \(chunks.count) stopped part-way; keeping what was read (\(error.localizedDescription))")
            }
            let segments = try await session.finish()
            all.append(contentsOf: segments)
            progress(Double(position + 1) / Double(pending.count), chunk.index)
            log.debug("Transcribed chunk \(chunk.index, privacy: .public): \(segments.count, privacy: .public) segments")
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Transcribes the end of a recording from its 16 kHz speaker buffer, from
    /// `start` seconds on. For a recording cut off by the app closing: the audio
    /// chunk being written then can't be opened (up to five minutes), but the
    /// speaker buffer holds the same audio.
    public func transcribeTail(meetingID: UUID, from start: TimeInterval) async throws -> [TranscriptSegment] {
        let rate = AudioFormats.diarization.sampleRate
        let audio = try AudioSamples(meetingID: meetingID)
        var position = max(0, Int(start * rate))
        guard position < audio.count else { return [] }

        let session = TranscriptionSession(locale: locale, timeOffset: start)
        try await session.start()
        do {
            // Four seconds at a time, so the buffer is never in memory whole.
            let piece = Int(rate) * 4
            while position < audio.count {
                try Task.checkCancellation()
                let samples = try audio.slice(position..<min(position + piece, audio.count))
                guard !samples.isEmpty else { break }
                await session.append(CapturedAudio(samples: samples, sampleRate: rate))
                position += samples.count
            }
        } catch is CancellationError {
            await session.cancel()
            throw CancellationError()
        } catch {
            let unlocked = await PowerState.isProtectedDataAvailable()
            if PhoneLocked.isCause(error) || !unlocked {
                await session.cancel()
                throw PhoneLocked()
            }
            DebugLog.shared.log("transcript", "the speaker buffer stopped part-way; keeping what was read (\(error.localizedDescription))")
        }
        return try await session.finish()
    }

    private func feed(_ file: AVAudioFile, into session: TranscriptionSession) async throws {
        let format = file.processingFormat
        let frameCapacity: AVAudioFrameCount = 8192

        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            guard let captured = CapturedAudio(buffer) else { break }
            await session.append(captured)
        }
    }
}
