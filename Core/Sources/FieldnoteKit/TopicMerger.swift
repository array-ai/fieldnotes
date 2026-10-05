import Foundation

/// Joins the per-excerpt topics into the summary's final sections.
///
/// Each excerpt is summarised on its own, so one subject discussed across a long
/// meeting comes back as several topics. A final model pass sees only their titles
/// and summaries and says which belong together (`Section.members`); this does the
/// rest without the model: collecting points, dropping repeats from overlapping
/// excerpts, and ordering by time. Pure, so it is tested off device.
public enum TopicMerger {

    public struct Section: Sendable {
        public var title: String
        public var summary: String
        /// Indices into the candidate topics.
        public var members: [Int]
        public var emoji: String?

        public init(title: String, summary: String, members: [Int], emoji: String? = nil) {
            self.title = title
            self.summary = summary
            self.members = members
            self.emoji = emoji
        }
    }

    /// - Parameters:
    ///   - sections: the model's grouping. Out-of-range or repeated indices are
    ///     ignored; candidates it left out keep a section of their own, so nothing
    ///     grounded is lost to a sloppy grouping.
    ///   - time: start time of a segment, for ordering.
    public static func merge(
        _ candidates: [SummaryTopic],
        sections: [Section],
        time: (UUID) -> TimeInterval
    ) -> [SummaryTopic] {
        var used = Set<Int>()
        var result: [SummaryTopic] = []

        for section in sections {
            let members = section.members.filter { candidates.indices.contains($0) && used.insert($0).inserted }
            guard !members.isEmpty else { continue }
            let title = section.title.trimmed().nilIfEmpty ?? candidates[members[0]].title
            let summary = section.summary.trimmed().nilIfEmpty ?? candidates[members[0]].summary
            var topic = combine(members.map { candidates[$0] }, title: title, summary: summary, time: time)
            topic.emoji = section.emoji?.trimmed().nilIfEmpty.map { String($0.prefix(2)) }
            result.append(topic)
        }

        // Anything the grouping missed: join by matching title, else stand alone.
        let leftovers = candidates.indices.filter { !used.contains($0) }.map { candidates[$0] }
        result.append(contentsOf: mergeByTitle(leftovers, time: time))

        return result.sorted { earliest($0, time) < earliest($1, time) }
    }

    /// Used when the grouping pass fails: topics with the same title are joined.
    public static func mergeByTitle(_ candidates: [SummaryTopic], time: (UUID) -> TimeInterval) -> [SummaryTopic] {
        var order: [String] = []
        var groups: [String: [SummaryTopic]] = [:]
        for topic in candidates {
            let key = normalized(topic.title)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(topic)
        }
        return order
            .compactMap { key in
                guard let members = groups[key], let first = members.first else { return nil }
                return combine(members, title: first.title, summary: first.summary, time: time)
            }
            .sorted { earliest($0, time) < earliest($1, time) }
    }

    private static func combine(
        _ members: [SummaryTopic],
        title: String,
        summary: String,
        time: (UUID) -> TimeInterval
    ) -> SummaryTopic {
        var seen = Set<String>()
        let points = members
            .flatMap(\.points)
            .filter { seen.insert(normalized($0.text)).inserted }
            .sorted { time($0.sourceSegmentID) < time($1.sourceSegmentID) }
        return SummaryTopic(title: title, summary: summary, points: points)
    }

    private static func earliest(_ topic: SummaryTopic, _ time: (UUID) -> TimeInterval) -> TimeInterval {
        topic.points.map { time($0.sourceSegmentID) }.min() ?? .greatestFiniteMagnitude
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension ActionItem {
    /// Action items grouped by who owns them, in order of first appearance, with
    /// unowned items last under "Unassigned". Owners match case-insensitively.
    public static func groupedByOwner(_ items: [ActionItem]) -> [(owner: String, items: [ActionItem])] {
        var order: [String] = []
        var names: [String: String] = [:]
        var groups: [String: [ActionItem]] = [:]
        var unassigned: [ActionItem] = []
        for item in items {
            guard let owner = item.owner?.trimmed().nilIfEmpty else {
                unassigned.append(item)
                continue
            }
            let key = owner.lowercased()
            if groups[key] == nil {
                order.append(key)
                names[key] = owner
            }
            groups[key, default: []].append(item)
        }
        var result = order.map { (owner: names[$0] ?? $0, items: groups[$0] ?? []) }
        if !unassigned.isEmpty { result.append((owner: "Unassigned", items: unassigned)) }
        return result
    }
}
