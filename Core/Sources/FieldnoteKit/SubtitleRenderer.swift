import Foundation

/// WebVTT and SRT, so a transcript can be dropped onto a recording in any editor or
/// player (spec 6.1).
public enum SubtitleRenderer {

    public static func webVTT(segments: [TranscriptSegment], speakerNames: [String: String] = [:]) -> String {
        var lines = ["WEBVTT", ""]
        for segment in segments {
            lines.append("\(Timecode.vtt(segment.start)) --> \(Timecode.vtt(effectiveEnd(of: segment)))")
            lines.append(cue(for: segment, speakerNames: speakerNames, voiceTags: true))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func srt(segments: [TranscriptSegment], speakerNames: [String: String] = [:]) -> String {
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(Timecode.srt(segment.start)) --> \(Timecode.srt(effectiveEnd(of: segment)))")
            lines.append(cue(for: segment, speakerNames: speakerNames, voiceTags: false))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A zero-length cue is invisible in every player. Give it a second.
    private static func effectiveEnd(of segment: TranscriptSegment) -> TimeInterval {
        segment.end > segment.start ? segment.end : segment.start + 1
    }

    private static func cue(for segment: TranscriptSegment, speakerNames: [String: String], voiceTags: Bool) -> String {
        guard let speakerID = segment.speakerID else { return segment.text }
        let name = SpeakerLabel.name(speakerID, names: speakerNames)
        return voiceTags ? "<v \(name)>\(segment.text)" : "\(name): \(segment.text)"
    }
}
