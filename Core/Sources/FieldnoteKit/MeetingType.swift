import Foundation

/// The four v1 presets. The type selects a prompt template (see `PromptTemplates`)
/// and nothing else — it never changes which model runs or where it runs.
public enum MeetingType: String, Codable, CaseIterable, Sendable {
    case siteVisit
    case scoping
    case incidentReview
    case internalMeeting

    public var displayName: String {
        switch self {
        case .siteVisit: "Site visit"
        case .scoping: "Scoping / pre-sales"
        case .incidentReview: "Incident review"
        case .internalMeeting: "Internal"
        }
    }

    public var symbolName: String {
        switch self {
        case .siteVisit: "wrench.and.screwdriver"
        case .scoping: "list.clipboard"
        case .incidentReview: "exclamationmark.triangle"
        case .internalMeeting: "person.2"
        }
    }
}
