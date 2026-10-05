import Foundation

/// Legacy. Meetings used to pick a type that selected a summary template; there is
/// now one prompt for every meeting and new meetings are always `.general`. The enum
/// stays because the value is persisted (SwiftData, backups, Live Activity
/// attributes) and older meetings still carry other types.
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
