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
    private let converter = FormatConverter(targetFormat: AudioFormats.diarization)
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

    /// - Returns: the 16 kHz samples just written, for live speaker identification.
    @discardableResult
    public func append(_ audio: CapturedAudio) throws -> [Float] {
        guard let buffer = audio.makeBuffer() else {
            throw DiarizationBufferError.unsupportedFormat
        }
        let converted = try converter.convert(buffer)
        guard let channel = converted.floatChannelData?[0] else { return [] }
        let frames = Int(converted.frameLength)
        guard frames > 0 else { return [] }
        let data = Data(bytes: channel, count: frames * MemoryLayout<Float>.size)
        try handle?.write(contentsOf: data)
        frameCount += frames
        return Array(UnsafeBufferPointer(start: channel, count: frames))
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
}

public enum DiarizationBufferError: Error {
    case unsupportedFormat
}
