#if os(iOS)
import AppIntents
import FieldnoteShared

/// The app's App Intents: the shared record intent and the shortcut below. Included
/// by the app target's root (Config/AppIntentsRoots/App.swift).
public struct FieldnoteIntents: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [FieldnoteSharedIntents.self] }
}

/// Puts "Record a Meeting" in Shortcuts, Spotlight and Siri, and in the Action
/// button's list of app actions, with no setup, along with the meeting-notes
/// questions in `MeetingNotesIntents.swift`.
struct FieldnoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordMeetingIntent(),
            phrases: [
                "Record a meeting with \(.applicationName)",
                "Start a \(.applicationName) recording",
                "Stop the \(.applicationName) recording",
            ],
            shortTitle: "Record Meeting",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: LastMeetingActionItemsIntent(),
            phrases: [
                "Action items from my last \(.applicationName) meeting",
                "What are my \(.applicationName) action items",
            ],
            shortTitle: "Action Items",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: LastMeetingSummaryIntent(),
            phrases: [
                "Summarise my last \(.applicationName) meeting",
                "Summarize my last \(.applicationName) meeting",
            ],
            shortTitle: "Last Meeting Summary",
            systemImageName: "text.badge.star"
        )
        AppShortcut(
            intent: NotesStatusIntent(),
            phrases: [
                "Are my \(.applicationName) notes ready",
            ],
            shortTitle: "Notes Ready?",
            systemImageName: "hourglass"
        )
        AppShortcut(
            intent: OpenLastMeetingIntent(),
            phrases: [
                "Open my last \(.applicationName) meeting",
            ],
            shortTitle: "Open Last Meeting",
            systemImageName: "doc.text"
        )
    }
}
#endif
