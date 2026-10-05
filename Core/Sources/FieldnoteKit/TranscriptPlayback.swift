import Foundation

/// Which transcript line is being spoken at a playback time, for highlighting and
/// scrolling the transcript under the audio player.
public enum TranscriptPlayback {

    /// After a line ends, it stays current through a pause this long, so the
    /// highlight doesn't flicker off between sentences.
    public static let holdThroughPause: TimeInterval = 3

    /// The index of the line playing at `time` in `segments` (sorted by start):
    /// the last line that has started, while it is still playing or within
    /// `holdThroughPause` of ending. Nil before the first line or in a long silence.
    public static func currentIndex(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        // Binary search for the last start <= time: transcripts run to thousands of
        // lines and this is called several times a second.
        var low = 0
        var high = segments.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = found, time <= segments[index].end + holdThroughPause else { return nil }
        return index
    }
}
