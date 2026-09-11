import Foundation

/// Stable per-speaker colours, so "S2" is the same colour every time the same meeting
/// is opened, exported or printed.
public enum SpeakerPalette {
    /// Chosen to stay distinguishable in greyscale print and for the common forms of
    /// colour blindness: blue, orange, teal, purple, brown, magenta.
    public static let colours: [(red: Double, green: Double, blue: Double)] = [
        (0.20, 0.44, 0.78),
        (0.87, 0.52, 0.16),
        (0.16, 0.60, 0.56),
        (0.52, 0.36, 0.75),
        (0.55, 0.42, 0.30),
        (0.78, 0.30, 0.55)
    ]

    public static func index(for label: String, among labels: [String]) -> Int {
        let sorted = labels.sorted()
        return (sorted.firstIndex(of: label) ?? 0) % colours.count
    }
}
