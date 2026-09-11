import AVFoundation
import Foundation

/// Joins the recording's chunks into one m4a for sharing.
///
/// Chunking is a durability decision (spec 4.1) and nobody wants to receive 37 files,
/// so the join happens at share time rather than at record time — the chunks on disk
/// stay the source of truth.
public enum AudioExporter {

    public static func exportSingleFile(
        chunks: [ChunkedAudioWriter.Chunk],
        to destination: URL
    ) async throws -> URL {
        guard !chunks.isEmpty else { throw ExportError.noAudio }
        if chunks.count == 1 {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: chunks[0].url, to: destination)
            return destination
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.compositionFailed }

        var cursor = CMTime.zero
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let asset = AVURLAsset(url: chunk.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.compositionFailed
        }
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .m4a)
        return destination
    }

    public enum ExportError: Error, LocalizedError {
        case noAudio
        case compositionFailed

        public var errorDescription: String? {
            switch self {
            case .noAudio: "This meeting has no audio on disk."
            case .compositionFailed: "The audio could not be joined into one file."
            }
        }
    }
}
