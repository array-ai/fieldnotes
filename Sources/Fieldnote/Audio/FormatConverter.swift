import AVFoundation

/// Converts arbitrary-format `AVAudioPCMBuffer`s to a fixed target format, one buffer
/// at a time. Every consumer of the raw mic tap needs this: the tap hands out whatever
/// format `AVAudioSession` actually negotiated (commonly 48 kHz), never the fixed
/// format the consumer was built around.
///
/// `primeMethod = .none` is not optional. With priming on, the converter inserts
/// leading frames, every subsequent timestamp drifts, and downstream alignment
/// degrades quietly (spec 4.3).
final class FormatConverter {
    enum ConverterError: Error {
        case cannotConvert(AVAudioFormat)
    }

    let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == targetFormat { return buffer }

        if converter == nil || sourceFormat != buffer.format {
            guard let made = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw ConverterError.cannotConvert(buffer.format)
            }
            made.primeMethod = .none
            made.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = made
            sourceFormat = buffer.format
        }
        guard let converter else { throw ConverterError.cannotConvert(buffer.format) }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw ConverterError.cannotConvert(buffer.format)
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
