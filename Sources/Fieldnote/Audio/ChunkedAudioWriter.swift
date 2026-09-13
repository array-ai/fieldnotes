import AVFoundation
import Foundation
import OSLog

/// Writes captured audio to disk continuously, in fixed-length chunks.
///
/// Nothing is held in memory waiting for the user to press stop. A 3-hour recording
/// that ends in an app kill loses at most the current chunk, and on relaunch the
/// chunks that made it are a complete recording up to that point (spec 4.1).
public actor ChunkedAudioWriter {

    public enum WriterError: Error {
        case unsupportedFormat
    }

    public struct Chunk: Codable, Hashable, Sendable {
        public var index: Int
        public var url: URL
        /// Offset of this chunk's first frame from the start of the recording.
        public var startTime: TimeInterval
        public var duration: TimeInterval
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "audio.writer")
    private let directory: URL
    private let chunkDuration: TimeInterval
    private let settings: [String: Any]
    /// `AVAudioFile.write(from:)` requires the buffer to exactly match the file's
    /// processing format -- no implicit conversion. The mic tap hands out whatever
    /// format `AVAudioSession` negotiated (commonly 48 kHz), almost never this. See
    /// `FormatConverter`.
    private let converter: FormatConverter

    private var file: AVAudioFile?
    private var currentIndex = 0
    private var currentStart: TimeInterval = 0
    private var currentDuration: TimeInterval = 0
    private(set) public var chunks: [Chunk] = []

    public init(
        meetingID: UUID,
        chunkDuration: TimeInterval = 300,
        settings: [String: Any] = AudioFormats.recordingSettings
    ) throws {
        self.directory = FieldnoteStorage.audioChunkDirectory(for: meetingID)
        self.chunkDuration = chunkDuration
        self.settings = settings
        let sampleRate = settings[AVSampleRateKey] as? Double ?? 44_100
        let channels = AVAudioChannelCount(settings[AVNumberOfChannelsKey] as? Int ?? 1)
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else { throw WriterError.unsupportedFormat }
        self.converter = FormatConverter(targetFormat: clientFormat)
        try FieldnoteStorage.ensureDirectory(directory)
        self.chunks = Self.existingChunks(in: directory)
        self.currentIndex = (chunks.last?.index ?? -1) + 1
        self.currentStart = chunks.reduce(0) { $0 + $1.duration }
    }

    public var totalDuration: TimeInterval { currentStart + currentDuration }

    public func write(_ audio: CapturedAudio) throws {
        guard let buffer = audio.makeBuffer() else { throw WriterError.unsupportedFormat }
        let converted = try converter.convert(buffer)
        let file = try fileForWriting()
        try file.write(from: converted)
        currentDuration += audio.duration
        if currentDuration >= chunkDuration {
            try rollChunk()
        }
    }

    /// Closes the current chunk without starting a new one. Called on interruption so
    /// the buffer in flight lands on disk rather than being dropped (spec 4.1).
    public func flush() throws {
        guard file != nil else { return }
        try rollChunk()
    }

    public func finish() throws -> [Chunk] {
        try flush()
        return chunks
    }

    private func fileForWriting() throws -> AVAudioFile {
        if let file { return file }
        let url = directory.appendingPathComponent(String(format: "chunk-%04d.m4a", currentIndex))
        let created = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: converter.targetFormat.commonFormat,
            interleaved: converter.targetFormat.isInterleaved
        )
        try? FieldnoteStorage.protect(url)
        file = created
        currentDuration = 0
        return created
    }

    private func rollChunk() throws {
        guard let file else { return }
        let url = file.url
        self.file = nil
        chunks.append(Chunk(index: currentIndex, url: url, startTime: currentStart, duration: currentDuration))
        currentStart += currentDuration
        currentDuration = 0
        currentIndex += 1
        log.debug("Rolled audio chunk \(self.currentIndex - 1, privacy: .public)")
    }

    /// Recovers chunks written before a crash or kill, in order.
    public static func existingChunks(in directory: URL) -> [Chunk] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var offset: TimeInterval = 0
        return urls
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated()
            .map { index, url in
                let duration = (try? AVAudioFile(forReading: url)).map {
                    Double($0.length) / $0.fileFormat.sampleRate
                } ?? 0
                let chunk = Chunk(index: index, url: url, startTime: offset, duration: duration)
                offset += duration
                return chunk
            }
    }
}
