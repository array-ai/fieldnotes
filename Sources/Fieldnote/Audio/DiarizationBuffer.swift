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
        try FieldnoteStorage.ensureDirectory(FieldnoteStorage.meetingDirectory(for: meetingID))
        self.url = Self.fileURL(for: meetingID)
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

    public static func fileURL(for meetingID: UUID) -> URL {
        FieldnoteStorage.meetingDirectory(for: meetingID).appendingPathComponent("diarization.f32")
    }

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

/// 16 kHz mono samples, read a slice at a time: from memory, or from a meeting's
/// speaker buffer on disk, so a three-hour meeting (~700 MB as floats) never has to
/// sit in memory whole.
public struct AudioSamples: Sendable {
    public let count: Int
    private let reader: @Sendable (Range<Int>) throws -> [Float]

    public init(_ samples: [Float]) {
        count = samples.count
        reader = { Array(samples[$0]) }
    }

    /// The meeting's speaker buffer (`diarization.f32`). Mapped per slice, so nothing
    /// is held open between reads.
    public init(meetingID: UUID) throws {
        let url = DiarizationBuffer.fileURL(for: meetingID)
        // No file reads as no audio, as the buffer itself did.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
        count = bytes / MemoryLayout<Float>.size
        reader = { range in
            guard !range.isEmpty else { return [] }
            // Mapped, not read: only the slice's pages are touched, and the whole
            // recording costs one copy (the array), not two.
            return try autoreleasepool {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                let size = MemoryLayout<Float>.size
                let bytes = data[(range.lowerBound * size)..<min(range.upperBound * size, data.count)]
                return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
    }

    public func slice(_ range: Range<Int>) throws -> [Float] {
        try reader(range.clamped(to: 0..<count))
    }

    /// Everything, for the models that need the whole recording at once.
    public func all() throws -> [Float] {
        try slice(0..<count)
    }
}

public enum DiarizationBufferError: Error {
    case unsupportedFormat
}
