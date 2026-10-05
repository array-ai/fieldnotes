import EventKit
import FieldnoteKit
import Foundation

/// Pushes action items into Reminders, and follow-ups into Calendar (spec 6.3).
///
/// Local system data, not a network call — the reminder lands in the user's own
/// database on their own device. Off by default, and permission is asked for at the
/// moment of first use, never at launch.
public actor RemindersExporter {

    private let store = EKEventStore()

    public init() {}

    public func requestRemindersAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    public func requestCalendarAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    /// Every Reminders list, by name. Picks up lists made since the store was
    /// opened, including ones still syncing from iCloud.
    public func availableLists() -> [(id: String, title: String)] {
        store.refreshSourcesIfNecessary()
        return store.calendars(for: .reminder)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { ($0.calendarIdentifier, $0.title) }
    }

    /// - Returns: how many reminders were created.
    @discardableResult
    public func export(
        actionItems: [ActionItem],
        from meeting: MeetingSnapshot,
        toListWithIdentifier listID: String?
    ) throws -> Int {
        let calendar = listID.flatMap { store.calendar(withIdentifier: $0) }
            ?? store.defaultCalendarForNewReminders()
        guard let calendar else { throw ExportError.noList }

        var created = 0
        for item in actionItems {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = item.task
            reminder.notes = notes(for: item, in: meeting)
            if let due = item.resolvedDueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: due
                )
            }
            try store.save(reminder, commit: false)
            created += 1
        }
        try store.commit()
        return created
    }

    /// The reminder carries the line it came from, so the person reading it in three
    /// days can see what was actually said rather than trusting a paraphrase.
    private func notes(for item: ActionItem, in meeting: MeetingSnapshot) -> String {
        var parts: [String] = []
        if let owner = item.owner, !owner.isEmpty { parts.append("Owner: \(owner)") }
        if let spoken = item.dueDate, !spoken.isEmpty { parts.append("Said: \(spoken)") }
        if let segment = meeting.segments.first(where: { $0.id == item.sourceSegmentID }) {
            let speaker = SpeakerLabel.name(segment.speakerID, names: meeting.speakerNames)
            parts.append("[\(Timecode.short(segment.start))] \(speaker): \(segment.text)")
        }
        parts.append("From \"\(meeting.title)\", \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: "\n\n")
    }

    public enum ExportError: Error, LocalizedError {
        case noList
        public var errorDescription: String? { "No Reminders list is available to write to." }
    }
}
