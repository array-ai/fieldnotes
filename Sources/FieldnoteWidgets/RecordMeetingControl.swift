import AppIntents
import FieldnoteShared
import SwiftUI
import WidgetKit

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
