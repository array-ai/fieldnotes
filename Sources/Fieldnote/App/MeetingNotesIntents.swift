#if os(iOS)
import AppIntents
import FieldnoteKit
import FieldnoteShared
import Foundation

// Siri asking about meetings: the last meeting's action items or summary, whether
// the notes are ready, and opening the last meeting. No parameters and no entities,
// so nothing is indexed and Siri can't search meetings; it gets one short answer,
// built from the notes (`SiriAnswers`), when asked.
//
// The phrases exist whether or not the user opted in, so each intent checks
// "Let Siri read meeting notes" itself, and each needs the phone unlocked: a locked
// phone mustn't read notes aloud, and the store's files are sealed while locked.

/// The app's side of these intents, set at launch like `MeetingRecordingControl`.
@MainActor
enum MeetingNotesForSiri {
    static var store: MeetingStore?
    static var open: ((UUID) -> Void)?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: SiriAnswers.enabledKey) }

    static let turnedOff: IntentDialog =
        "To hear your meeting notes, turn on Let Siri Read Meeting Notes in Fieldnote's Settings."

    static func recentMeetings() async throws -> [MeetingSnapshot] {
        guard let store else { throw MeetingRecordingControl.Failure.appNotReady }
        return try await store.recentSnapshots(limit: 20)
    }
}

struct LastMeetingActionItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Action Items from Last Meeting"
    static let description = IntentDescription("Reads the action items from your last meeting's notes.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard MeetingNotesForSiri.enabled else { return .result(dialog: MeetingNotesForSiri.turnedOff) }
        guard let meeting = SiriAnswers.lastFinished(try await MeetingNotesForSiri.recentMeetings()) else {
            return .result(dialog: "You have no finished meeting notes yet.")
        }
        DebugLog.shared.log("siri", "read the last meeting's action items")
        return .result(dialog: IntentDialog(stringLiteral: SiriAnswers.actionItems(meeting)))
    }
}

struct LastMeetingSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Summary of Last Meeting"
    static let description = IntentDescription("Reads the overview from your last meeting's notes.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard MeetingNotesForSiri.enabled else { return .result(dialog: MeetingNotesForSiri.turnedOff) }
        guard let meeting = SiriAnswers.lastFinished(try await MeetingNotesForSiri.recentMeetings()) else {
            return .result(dialog: "You have no finished meeting notes yet.")
        }
        DebugLog.shared.log("siri", "read the last meeting's summary")
        return .result(dialog: IntentDialog(stringLiteral: SiriAnswers.summary(meeting)))
    }
}

/// Answers without the meeting's title unless the user opted in.
struct NotesStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Are My Notes Ready"
    static let description = IntentDescription("Says whether the notes for your last meeting are ready.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meetings = try await MeetingNotesForSiri.recentMeetings()
        let answer = SiriAnswers.status(meetings, includeTitle: MeetingNotesForSiri.enabled)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Opens the app on the last meeting. Says nothing about it, so it needs no opt-in.
struct OpenLastMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Last Meeting"
    static let description = IntentDescription("Opens your last meeting in Fieldnote.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        let meetings = try await MeetingNotesForSiri.recentMeetings()
        if let latest = meetings.max(by: { $0.startedAt < $1.startedAt }) {
            MeetingNotesForSiri.open?(latest.id)
        }
        return .result()
    }
}
#endif
