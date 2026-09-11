import FieldnoteKit
import Foundation
import FoundationModels

/// Suggests a meeting type from the opening minutes, so the user usually does not
/// have to pick one. Cheap classification, so it runs on AFM 3 Core rather than Core
/// Advanced (spec 4.5).
///
/// A suggestion, never an override: the user's choice always wins, and a wrong guess
/// costs one tap.
public struct MeetingTypeClassifier: Sendable {

    @Generable
    struct Classification {
        @Guide(description: "One of: siteVisit, scoping, incidentReview, internalMeeting")
        var type: String
    }

    public init() {}

    public func suggest(from segments: [TranscriptSegment], limit: Int = 40) async -> MeetingType? {
        let opening = segments.prefix(limit).map(\.text).joined(separator: " ")
        guard opening.count > 200 else { return nil }

        let instructions = """
            You classify the opening of a work meeting recorded by an IT managed \
            service provider. Answer with exactly one of these identifiers and nothing \
            else: siteVisit, scoping, incidentReview, internalMeeting.

            siteVisit: an engineer is on a client site working on equipment.
            scoping: discussing possible future work, requirements or price.
            incidentReview: reviewing something that already broke.
            internalMeeting: staff of the provider talking among themselves.
            """
        do {
            let session = try OnDeviceModel.session(tier: .core, instructions: instructions)
            let response = try await session.respond(
                to: "Opening of the meeting:\n\(opening)",
                generating: Classification.self
            )
            return MeetingType(rawValue: response.content.type.trimmed())
        } catch {
            return nil
        }
    }
}
