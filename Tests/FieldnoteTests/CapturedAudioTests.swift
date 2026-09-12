import AVFoundation
import Testing

@testable import Fieldnote

@Suite("Captured audio")
struct CapturedAudioTests {

    /// Builds a non-interleaved Float32 buffer -- the only format the tap ever
    /// hands `CapturedAudio.init?`, per its own doc comment.
    private func buffer(channels: [[Float]], sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let frameCount = channels.first?.count ?? 0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let destination = buffer.floatChannelData!
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                destination[index].update(from: source.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    @Test("Round-tripping through a buffer preserves samples, channel count and sample rate")
    func roundTrip() throws {
        let source = buffer(channels: [[0.1, -0.2, 0.3, -0.4], [0.5, -0.6, 0.7, -0.8]], sampleRate: 44_100)

        let captured = try #require(CapturedAudio(source))
        #expect(captured.channels == [[0.1, -0.2, 0.3, -0.4], [0.5, -0.6, 0.7, -0.8]])
        #expect(captured.sampleRate == 44_100)
        #expect(captured.frameCount == 4)
        #expect(captured.duration == 4.0 / 44_100)

        let rebuilt = try #require(captured.makeBuffer())
        #expect(rebuilt.format.channelCount == 2)
        #expect(rebuilt.format.sampleRate == 44_100)
        #expect(rebuilt.frameLength == 4)
        let rebuiltChannels = (0..<2).map { channel in
            Array(UnsafeBufferPointer(start: rebuilt.floatChannelData![channel], count: 4))
        }
        #expect(rebuiltChannels == captured.channels)
    }

    @Test("A mono buffer round-trips as a single channel")
    func mono() throws {
        let source = buffer(channels: [[1, 2, 3]])
        let captured = try #require(CapturedAudio(source))
        #expect(captured.channels.count == 1)
        #expect(captured.frameCount == 3)
    }

    @Test("An interleaved-format buffer is rejected")
    func interleavedRejected() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        #expect(CapturedAudio(buffer) == nil)
    }

    @Test("A non-Float32 buffer is rejected")
    func nonFloat32Rejected() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        #expect(CapturedAudio(buffer) == nil)
    }

    @Test("An empty buffer is rejected rather than producing a zero-length capture")
    func emptyBufferRejected() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        // frameLength defaults to 0 until set -- exactly "no frames captured yet",
        // which is what a buffer looks like before AVAudioEngine fills it.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        #expect(CapturedAudio(buffer) == nil)
    }

    @Test("Silence reads as the meter floor, not zero divided by zero")
    func silentPeakLevel() throws {
        let captured = try #require(CapturedAudio(buffer(channels: [[0, 0, 0, 0]])))
        #expect(captured.peakLevel == 0)
    }

    @Test("Full-scale audio reads as a full meter")
    func fullScalePeakLevel() throws {
        let captured = try #require(CapturedAudio(buffer(channels: [[1, -1, 0.5]])))
        #expect(captured.peakLevel == 1)
    }

    @Test("Peak level looks only at the first channel")
    func peakLevelIsFirstChannelOnly() throws {
        let captured = try #require(CapturedAudio(buffer(channels: [[0, 0, 0], [1, 1, 1]])))
        #expect(captured.peakLevel == 0)
    }
}
