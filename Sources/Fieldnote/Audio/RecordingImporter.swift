import AVFoundation
import FieldnoteKit
import Foundation

/// Brings in a recording made elsewhere — a voice memo, a dedicated recorder, a file
/// downloaded from a meeting service such as Fireflies — so it is transcribed,
/// split by speaker and summarised like one recorded here.
///
/// The file is played through the same two writers a live recording feeds: m4a
/// chunks on disk, and the 16 kHz buffer for speaker identification. There is no
/// live transcript, so the pipeline transcribes from the chunks. Nothing about the
/// pipeline needs to know the meeting was imported.
public enum RecordingImporter {

    public enum ImportError: Error, LocalizedError {
        case unreadable(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "\(name) couldn't be read as audio. Export it as MP3, M4A or WAV and try again."
            case .empty:
                "That file has no audio in it."
            }
        }
    }

    public struct Result: Sendable {
        public var chunks: [ChunkedAudioWriter.Chunk]
        public var duration: TimeInterval
    }

    /// - Parameter progress: 0...1 through the file.
    public static func importAudio(
        from url: URL,
        meetingID: UUID,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        guard file.length > 0 else { throw ImportError.empty }

        let writer = try ChunkedAudioWriter(meetingID: meetingID)
        let speakerBuffer = try DiarizationBuffer(meetingID: meetingID)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        var lastReported = 0.0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            guard let audio = CapturedAudio(buffer) else { throw ImportError.unreadable(url.lastPathComponent) }
            try await writer.write(audio)
            try await speakerBuffer.append(audio)

            let fraction = Double(file.framePosition) / Double(file.length)
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                progress(fraction)
            }
        }

        let chunks = try await writer.finish()
        try await speakerBuffer.close()
        progress(1)
        return Result(chunks: chunks, duration: Double(file.length) / format.sampleRate)
    }
}
