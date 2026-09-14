import Foundation

/// `general` plus the four v1 presets. The type selects a prompt template (see
/// `PromptTemplates`) and nothing else — it never changes which model runs or where
/// it runs.
///
/// `general` is the floor: a new meeting starts here rather than on any specific
/// preset, because nothing is known about it yet. `MeetingTypeClassifier` only ever
/// upgrades away from it; it is never a suggestion in its own right.
public enum MeetingType: String, Codable, CaseIterable, Sendable {
    case general
    case siteVisit
    case scoping
    case incidentReview
    case internalMeeting

    public var displayName: String {
        switch self {
        case .general: "General"
        case .siteVisit: "Site visit"
        case .scoping: "Scoping / pre-sales"
        case .incidentReview: "Incident review"
        case .internalMeeting: "Internal"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "note.text"
        case .siteVisit: "wrench.and.screwdriver"
        case .scoping: "list.clipboard"
        case .incidentReview: "exclamationmark.triangle"
        case .internalMeeting: "person.2"
        }
    }
}
