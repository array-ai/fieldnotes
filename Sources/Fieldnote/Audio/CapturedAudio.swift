import AVFoundation
import Foundation

/// A slice of captured microphone audio, as plain values.
///
/// # Why this exists rather than passing the buffer around
///
/// The recorder forks every slice to three consumers, each its own actor: the disk
/// writer, the diarization buffer and the transcriber. An `AVAudioPCMBuffer` cannot
/// serve that. It is a class, so any copy made from one shares the original's
/// isolation region — even a freshly allocated copy, because reading the source's
/// samples merges the two regions — and a `sending` result is rejected for exactly
/// that reason. Sending it to the first actor taints it for the other two.
///
/// An array of samples has no isolation region at all. The cost is one copy out of
/// the engine's buffer and one rebuild per consumer, against file I/O and speech
/// recognition, which is not a trade worth agonising over.
///
/// Copying out of the tap's buffer is also required for a second, older reason: the
/// engine reuses that buffer the moment the callback returns, so anything that
/// outlives the callback must own its samples or it will play back somebody else's
/// audio a few seconds later.
public struct CapturedAudio: Sendable {
    /// Non-interleaved Float32 samples, one array per channel.
    public var channels: [[Float]]
    public var sampleRate: Double

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// - Returns: nil for formats this app never captures — anything but
    ///   non-interleaved Float32, which is what `AVAudioEngine`'s input node vends.
    public init?(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var channels: [[Float]] = []
        channels.reserveCapacity(Int(buffer.format.channelCount))
        for channel in 0..<Int(buffer.format.channelCount) {
            channels.append(Array(UnsafeBufferPointer(start: data[channel], count: frames)))
        }
        self.channels = channels
        self.sampleRate = buffer.format.sampleRate
    }

    /// Rebuilds a buffer for the frameworks that need one. Each consumer does this in
    /// its own isolation region, from values, so nothing is shared.
    public func makeBuffer() -> AVAudioPCMBuffer? {
        guard !channels.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: AVAudioChannelCount(channels.count),
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let destination = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination[index].update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    /// Peak level of the first channel, normalised to 0...1 for the meter.
    public var peakLevel: Double {
        guard let samples = channels.first, !samples.isEmpty else { return 0 }
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        // -60 dBFS floor: a quiet room reads near zero, speech fills the meter.
        let db = 20 * log10(max(Double(peak), 0.000_001))
        return min(1, max(0, (db + 60) / 60))
    }
}
