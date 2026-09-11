import AVFoundation

extension AVAudioPCMBuffer {
    /// The buffer handed to an engine tap is reused by the engine as soon as the
    /// callback returns. Anything that leaves the callback must be a copy, or you get
    /// audio that is intermittently someone else's — usually a few seconds later,
    /// usually only on a real device, usually in a long meeting.
    ///
    /// Returns `sending`: the result is a brand-new buffer that nothing else
    /// references, so it belongs to no isolation region and may be handed to any
    /// actor. Without this the compiler infers the copy's region from the buffer it
    /// was derived from — and once that region has been sent to one actor, every
    /// later copy is rejected too, which is exactly what happened here.
    func deepCopy() -> sending AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)

        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        if let source = int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        return nil
    }

    /// Peak level of channel 0, normalised to 0...1 for the meter.
    var peakLevel: Double {
        guard let data = floatChannelData?[0], frameLength > 0 else { return 0 }
        var peak: Float = 0
        for frame in 0..<Int(frameLength) {
            peak = max(peak, abs(data[frame]))
        }
        // -60 dBFS floor: quiet room reads as near-zero, speech fills the meter.
        let db = 20 * log10(max(Double(peak), 0.000_001))
        return min(1, max(0, (db + 60) / 60))
    }
}
