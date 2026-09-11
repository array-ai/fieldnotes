import AVFoundation
import Foundation

/// The second consumer of the audio fork (spec 4.2): 16 kHz mono Float32, appended to
/// a raw file on disk for one batch diarization pass on stop.
///
/// On disk rather than in RAM for the same reason the audio chunks are: a 3-hour
/// meeting is ~170 MB of Float32 at 16 kHz, and holding that in memory is how a
/// long recording gets killed by the system just before the user presses stop.
///
/// No live diarization. Diarize once, on stop, against the whole buffer.
public actor DiarizationBuffer {

    private let url: URL
    private var handle: FileHandle?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private(set) public var frameCount: Int = 0

    public init(meetingID: UUID) throws {
        let directory = FieldnoteStorage.meetingDirectory(for: meetingID)
        try FieldnoteStorage.ensureDirectory(directory)
        self.url = directory.appendingPathComponent("diarization.f32")
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            try? FieldnoteStorage.protect(url)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle?.seekToEnd()
        let existingBytes = (try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )[.size] as? Int) ?? 0
        // Resuming after a kill: the samples already on disk still count.
        self.frameCount = existingBytes / MemoryLayout<Float>.size
    }

    public var fileURL: URL { url }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        let converted = try convert(buffer)
        guard let channel = converted.floatChannelData?[0] else { return }
        let frames = Int(converted.frameLength)
        guard frames > 0 else { return }
        let data = Data(bytes: channel, count: frames * MemoryLayout<Float>.size)
        try handle?.write(contentsOf: data)
        frameCount += frames
    }

    public func flush() throws {
        try handle?.synchronize()
    }

    public func close() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    /// Reads the whole buffer back for the diarization pass.
    public func samples() throws -> [Float] {
        try flush()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    public func discard() {
        try? close()
        try? FileManager.default.removeItem(at: url)
        frameCount = 0
    }

    // MARK: - Conversion

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == AudioFormats.diarization { return buffer }

        if converter == nil || sourceFormat != buffer.format {
            guard let made = AudioFormats.makeDiarizationConverter(from: buffer.format) else {
                throw DiarizationBufferError.cannotConvert(buffer.format)
            }
            converter = made
            sourceFormat = buffer.format
        }
        guard let converter else { throw DiarizationBufferError.cannotConvert(buffer.format) }

        let ratio = AudioFormats.diarization.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioFormats.diarization, frameCapacity: capacity) else {
            throw DiarizationBufferError.cannotConvert(buffer.format)
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }
}

public enum DiarizationBufferError: Error {
    case cannotConvert(AVAudioFormat)
}
