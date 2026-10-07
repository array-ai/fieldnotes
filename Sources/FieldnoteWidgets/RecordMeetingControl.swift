import AppIntents
import FieldnoteShared
import SwiftUI
import WidgetKit

/// The widget extension's App Intents: the shared record intent its control runs.
/// Included by the extension target's root (Config/AppIntentsRoots/Widgets.swift).
public struct FieldnoteWidgetsIntents: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [FieldnoteSharedIntents.self] }
}

/// A control for the Action button, Control Centre and the Lock Screen: one press
/// starts recording a meeting, another stops and saves it. The press runs
/// `RecordMeetingIntent` in the app.
struct RecordMeetingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.publicarray.fieldnotes.record") {
            ControlWidgetButton(action: RecordMeetingIntent()) {
                Label("Record Meeting", systemImage: "record.circle")
            }
        }
        .displayName("Record Meeting")
        .description("Start recording a meeting, or stop the one being recorded.")
    }
}
