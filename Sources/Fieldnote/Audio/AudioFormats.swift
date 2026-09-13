import AVFoundation
import Foundation

public enum AudioFormats {

    /// What FluidAudio wants: 16 kHz, mono, Float32, non-interleaved (spec 4.2).
    public static var diarization: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    /// What gets kept on disk: AAC in m4a. A 3-hour meeting is roughly 90 MB at
    /// 64 kbps mono, which is the difference between "keep everything" and "delete
    /// recordings to make room".
    public static var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
    }

}
