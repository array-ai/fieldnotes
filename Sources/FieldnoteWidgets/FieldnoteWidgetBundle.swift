import FieldnoteKit
import FieldnoteShared
import SwiftUI
import WidgetKit

@main
struct FieldnoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordMeetingControl()
    }
}
