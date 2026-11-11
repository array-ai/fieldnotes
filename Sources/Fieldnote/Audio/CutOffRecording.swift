import FieldnoteKit
import Foundation

/// Puts back the end of a recording that the app closing cut off.
///
/// The recorder saves audio twice: as m4a chunks for playback and sharing, and as
/// the 16 kHz speaker buffer. An m4a chunk only becomes readable when it is closed,
/// so a crash or a kill loses the one being written (up to five minutes, or all of
/// a shorter recording). The speaker buffer is plain samples and survives. This
/// writes the missing stretch back as chunks from that buffer, so the whole meeting
/// plays, exports and transcribes. That stretch is 16 kHz audio, so it sounds
/// duller than the rest.
enum CutOffRecording {

    /// - Returns: the seconds of audio put back, or nil when nothing was missing.
    static func repairIfNeeded(meetingID: UUID) async throws -> TimeInterval? {
        let directory = FieldnoteStorage.audioChunkDirectory(for: meetingID)
        let chunks = ChunkedAudioWriter.existingChunks(in: directory)
        // Only the last chunk can be the cut-off one. An unreadable chunk earlier
        // would shift the chunks' timeline, and the buffer's wouldn't line up.
        guard !chunks.dropLast().contains(where: { $0.duration <= 0 }) else { return nil }

        let rate = AudioFormats.diarization.sampleRate
        let audio = try AudioSamples(meetingID: meetingID)
        let saved = chunks.reduce(0) { $0 + $1.duration }
        let buffered = Double(audio.count) / rate
        // The two are written from the same audio and agree to well under a second;
        // ten leaves room for rounding over many chunks.
        guard buffered - saved > 10 else { return nil }

        // The cut-off chunk is set aside, not deleted: it can't be opened, but its
        // name would be taken by the chunk written in its place.
        if let last = chunks.last, last.duration <= 0 {
            let aside = last.url.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: last.url, to: aside)
        }

        let writer = try ChunkedAudioWriter(meetingID: meetingID)
        var position = Int(saved * rate)
        // Four seconds at a time, so the buffer is never in memory whole.
        let piece = Int(rate) * 4
        while position < audio.count {
            try Task.checkCancellation()
            let samples = try audio.slice(position..<min(position + piece, audio.count))
            guard !samples.isEmpty else { break }
            try await writer.write(CapturedAudio(samples: samples, sampleRate: rate))
            position += samples.count
        }
        _ = try await writer.finish()
        return buffered - saved
    }
}
