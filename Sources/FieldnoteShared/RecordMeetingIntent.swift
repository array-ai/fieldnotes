#if os(iOS)
import AppIntents
import Foundation

/// Starts recording a new meeting, or stops and saves the one being recorded. Run
/// from the Action button, Control Centre, the Lock Screen or Siri.
///
/// Shared by the app and the widget extension (the control lives in the extension),
/// but always performed in the app's process: an `AudioRecordingIntent` runs there,
/// may start recording with the app in the background, and must show a Live
/// Activity while it records, which the recorder already does.
public struct RecordMeetingIntent: AudioRecordingIntent {
    public static let title: LocalizedStringResource = "Record a Meeting"
    public static let description = IntentDescription(
        "Starts recording a new meeting in Fieldnote, or stops and saves the one being recorded."
    )

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let toggle = MeetingRecordingControl.toggle else {
            throw MeetingRecordingControl.Failure.appNotReady
        }
        let message = try await toggle()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// Registers this package's one intent with Xcode's App Intents metadata. Without
/// it, intents in a Swift package never reach the app's Metadata.appintents and iOS
/// can't run them: the Action button animated and did nothing (builds 40–49).
public struct FieldnoteSharedIntents: AppIntentsPackage {}

/// The app's side of `RecordMeetingIntent`. The app sets `toggle` at launch; the
/// widget extension never does, and doesn't need to, as the intent runs in the app.
@MainActor
public enum MeetingRecordingControl {
    /// Starts or stops a recording and returns what to say about it.
    public static var toggle: (@MainActor () async throws -> String)?

    public enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case appNotReady
        case needsFirstRecording

        public var localizedStringResource: LocalizedStringResource {
            switch self {
            case .appNotReady:
                "Fieldnote isn't ready yet. Open it once, then try again."
            case .needsFirstRecording:
                "Start your first recording in Fieldnote, to see the note on consent. After that this starts one straight away."
            }
        }
    }
}
#endif
