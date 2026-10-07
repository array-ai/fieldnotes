#if os(iOS)
import AppIntents
import FieldnoteShared

/// The app's App Intents: the shared record intent and the shortcut below. Included
/// by the app target's root (Config/AppIntentsRoots/App.swift).
public struct FieldnoteIntents: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [FieldnoteSharedIntents.self] }
}

/// Puts "Record a Meeting" in Shortcuts, Spotlight and Siri, and in the Action
/// button's list of app actions, with no setup.
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
    }
}
#endif
