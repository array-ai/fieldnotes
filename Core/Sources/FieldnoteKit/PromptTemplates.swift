import Foundation

/// Instruction sets, one per meeting type, plus the two prompts that do the work.
///
/// Prompt edits are code changes with no compiler. Re-run the fixed recording set
/// after every change here and read the output yourself (spec 4.5). Apple's
/// Evaluations framework automates this and is v2 (spec 11.4); its absence is not a
/// licence to skip the manual pass.
public struct SummaryTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var meetingType: MeetingType
    /// Session instructions. Sets the reporting stance for the whole meeting.
    public var instructions: String
    /// What this meeting type wants pulled out, appended to each chunk prompt.
    public var focus: String
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        meetingType: MeetingType,
        instructions: String,
        focus: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.meetingType = meetingType
        self.instructions = instructions
        self.focus = focus
        self.isBuiltIn = isBuiltIn
    }
}

public enum PromptTemplates {

    /// Shared across every meeting type. The rules that keep output honest live here,
    /// not in the per-type text, so a user editing a template cannot delete them.
    public static let groundingRules = """
        Rules that always apply:
        - Report only what was said. Do not infer, do not fill gaps, do not add advice.
        - Every decision, action and open question must cite the line numbers it came \
        from. A point you cannot cite must be left out.
        - Copy product, vendor and site names exactly as they appear, even when they \
        look misspelt. They were transcribed from speech and the spelling is the \
        user's to fix.
        - Do not describe people. No traits, no tone, no judgements about anyone.
        - If the excerpt contains nothing of substance, return empty lists.
        """

    public static func builtIn(for type: MeetingType) -> SummaryTemplate {
        switch type {
        case .siteVisit:
            SummaryTemplate(
                name: "Site visit",
                meetingType: .siteVisit,
                instructions: """
                    You summarise notes from an on-site IT service visit for a managed \
                    service provider. The audio was recorded in a room, often with \
                    background noise, so expect broken sentences and mis-transcribed \
                    product names.

                    \(groundingRules)
                    """,
                focus: """
                    Pull out in particular: equipment and assets discussed, faults \
                    found, parts or licences required, and follow-up work agreed.
                    """,
                isBuiltIn: true
            )
        case .scoping:
            SummaryTemplate(
                name: "Scoping / pre-sales",
                meetingType: .scoping,
                instructions: """
                    You summarise a scoping or pre-sales conversation for a managed \
                    service provider.

                    \(groundingRules)
                    """,
                focus: """
                    Pull out in particular: stated requirements, constraints \
                    (technical, timing, contractual), anything said about budget, and \
                    who holds the decision.
                    """,
                isBuiltIn: true
            )
        case .incidentReview:
            SummaryTemplate(
                name: "Incident review",
                meetingType: .incidentReview,
                instructions: """
                    You summarise an incident review. These conversations get blunt. \
                    Record what was said about the incident; do not soften it and do \
                    not characterise anyone's conduct.

                    \(groundingRules)
                    """,
                focus: """
                    Pull out in particular: the timeline of events with times where \
                    given, stated causes, remediation performed or agreed, and \
                    prevention work committed to.
                    """,
                isBuiltIn: true
            )
        case .internalMeeting:
            SummaryTemplate(
                name: "Internal",
                meetingType: .internalMeeting,
                instructions: """
                    You summarise an internal team meeting.

                    \(groundingRules)
                    """,
                focus: "Pull out decisions made and tasks people committed to.",
                isBuiltIn: true
            )
        }
    }

    /// The map-phase prompt. One chunk of numbered transcript in, structured notes out.
    public static func chunkPrompt(
        template: SummaryTemplate,
        chunk: TranscriptChunk,
        chunkIndex: Int,
        chunkCount: Int
    ) -> String {
        """
        Excerpt \(chunkIndex + 1) of \(chunkCount) from a meeting transcript. Each \
        line is numbered and prefixed with the speaker label. Cite these line numbers.

        \(template.focus)

        Transcript:
        \(chunk.promptText())
        """
    }

    /// The shorter, neutral retry after a guardrail trip. Same excerpt, less framing,
    /// no words that read as loaded. Better a thin section than a silently missing one.
    public static func neutralChunkPrompt(chunk: TranscriptChunk, chunkIndex: Int, chunkCount: Int) -> String {
        """
        Excerpt \(chunkIndex + 1) of \(chunkCount) from a work meeting transcript. \
        Lines are numbered.

        List the topics covered, any tasks people agreed to do, and any questions left \
        open. Cite line numbers. Report only what is written.

        Transcript:
        \(chunk.promptText())
        """
    }

    /// The reduce phase. Runs over chunk notes, never over raw transcript.
    public static func rollupPrompt(points: [String], meetingTitle: String, type: MeetingType) -> String {
        """
        Below are notes taken from consecutive excerpts of one \
        \(type.displayName.lowercased()) titled "\(meetingTitle)".

        Write a 3 to 6 sentence overview of the meeting as a whole. State what was \
        discussed and what came of it. Do not open with "In this meeting" or similar. \
        Do not add anything the notes do not contain.

        Notes:
        \(points.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
