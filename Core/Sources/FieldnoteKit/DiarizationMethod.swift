import Foundation

/// Which on-device model answers "who spoke when". Chosen in Settings; every option
/// is a CoreML model vendored into the app bundle, so switching never downloads
/// anything (constraint 1).
///
/// The choice is read when the diarizing stage runs, so it applies to the next
/// recording processed. A meeting whose diarizing stage already checkpointed keeps
/// the labels it has.
public enum DiarizationMethod: String, Codable, CaseIterable, Sendable {
    /// NVIDIA Nemotron 3 Diarization: an end-to-end streaming Sortformer that
    /// predicts up to eight speakers directly, overlap included. No clustering step.
    case nemotron3
    /// pyannote community-1: segmentation, WeSpeaker embeddings, then PLDA + VBx
    /// clustering over the whole recording. The successor to pyannote 3.1.
    case pyannoteCommunity1
    /// pyannote 3.1-style: segmentation-3.0 plus WeSpeaker embeddings with greedy
    /// online clustering. What Fieldnote shipped with first.
    case pyannoteLegacy

    /// The UserDefaults key the app stores the choice under.
    public static let defaultsKey = "diarizationMethod"

    public static let `default`: DiarizationMethod = .nemotron3

    /// Resolves a stored raw value, falling back to the default for anything
    /// missing or no longer recognised.
    public init(storedValue: String?) {
        self = storedValue.flatMap(DiarizationMethod.init(rawValue:)) ?? .default
    }

    public var displayName: String {
        switch self {
        case .nemotron3: "Nemotron 3 (NVIDIA)"
        case .pyannoteCommunity1: "pyannote community-1"
        case .pyannoteLegacy: "pyannote 3.1 (legacy)"
        }
    }

    public var summary: String {
        switch self {
        case .nemotron3:
            "End-to-end, handles overlapping speech. Up to 8 speakers."
        case .pyannoteCommunity1:
            "Clusters the whole recording at once. No fixed speaker limit."
        case .pyannoteLegacy:
            "The pipeline Fieldnote first shipped with, kept for comparison."
        }
    }
}
