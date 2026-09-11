import Foundation

/// The three post-recording stages, in order. Each one checkpoints to disk when it
/// completes, so a task killed by the system resumes at the next stage rather than
/// restarting from raw audio (spec 4.7).
public enum ProcessingStage: String, Codable, CaseIterable, Sendable, Comparable {
    case transcribing
    case diarizing
    case summarising

    public var displayName: String {
        switch self {
        case .transcribing: "Transcribing"
        case .diarizing: "Identifying speakers"
        case .summarising: "Summarising"
        }
    }

    /// Share of total progress. Transcription dominates wall-clock on a long meeting.
    public var progressWeight: Int64 {
        switch self {
        case .transcribing: 60
        case .diarizing: 20
        case .summarising: 20
        }
    }

    var order: Int {
        switch self {
        case .transcribing: 0
        case .diarizing: 1
        case .summarising: 2
        }
    }

    public static func < (lhs: ProcessingStage, rhs: ProcessingStage) -> Bool {
        lhs.order < rhs.order
    }

    /// Units of progress completed by every stage strictly before this one.
    public var precedingWeight: Int64 {
        ProcessingStage.allCases.filter { $0 < self }.reduce(0) { $0 + $1.progressWeight }
    }

    public static var totalWeight: Int64 {
        allCases.reduce(0) { $0 + $1.progressWeight }
    }
}

/// Where a meeting is in its lifecycle. Persisted on `Meeting`.
public enum ProcessingState: String, Codable, Sendable {
    case recording
    case queued
    case transcribing
    case diarizing
    case summarising
    case complete
    case failed

    public var isTerminal: Bool { self == .complete || self == .failed }

    public init(stage: ProcessingStage) {
        switch stage {
        case .transcribing: self = .transcribing
        case .diarizing: self = .diarizing
        case .summarising: self = .summarising
        }
    }
}
