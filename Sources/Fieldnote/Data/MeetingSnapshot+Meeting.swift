import FieldnoteKit
import Foundation

extension MeetingSnapshot {
    /// Copies a stored meeting into the `Sendable` value type the renderers, the
    /// share builder and the UI work with. SwiftData objects never leave the store
    /// actor.
    ///
    /// Delegates to the memberwise initialiser rather than assigning properties:
    /// `MeetingSnapshot` lives in another module, so an extension here cannot
    /// initialise its stored properties directly.
    init(meeting: Meeting) {
        self.init(
            id: meeting.id,
            title: meeting.title,
            type: meeting.type,
            startedAt: meeting.startedAt,
            duration: meeting.duration,
            state: meeting.processingState,
            failureMessage: meeting.failureMessage,
            folderName: meeting.folder?.name,
            segments: meeting.orderedSegments.map(\.value),
            speakerNames: Dictionary(
                meeting.speakers.map { ($0.label, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            summary: meeting.summary?.summary,
            latitude: meeting.latitude,
            longitude: meeting.longitude,
            // Empty means "looked, found nothing" — shown as no name.
            placeName: meeting.placeName?.nilIfEmpty
        )
    }
}
