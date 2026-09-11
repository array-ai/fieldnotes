import AVFoundation
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
            let session = TranscriptionSession(locale: locale, timeOffset: chunk.startTime)
            try await session.start()
            try await feed(chunk.url, into: session)
            let segments = try await session.finish()
            all.append(contentsOf: segments)
            progress(Double(position + 1) / Double(pending.count), chunk.index)
            log.debug("Transcribed chunk \(chunk.index, privacy: .public): \(segments.count, privacy: .public) segments")
        }
        return all.sorted { $0.start < $1.start }
    }

    private func feed(_ url: URL, into session: TranscriptionSession) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCapacity: AVAudioFrameCount = 8192

        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            await session.append(buffer)
        }
    }
}
