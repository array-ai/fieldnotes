import FieldnoteKit
import Foundation
import SwiftData

/// # Storage choice
///
/// SwiftData, not GRDB (spec 5 says pick one and stay with it).
///
/// The cost of that choice is FTS5: SwiftData has no full-text index, so search runs
/// over a denormalised `searchText` column with a `contains` predicate. That is fine
/// for one engineer's meetings and it is not fine for tens of thousands of them. The
/// trigger to move to GRDB is search latency on a real corpus, not taste — and the
/// column is there so the move is a migration rather than a rewrite.

@Model
public final class Meeting {
    #Index<Meeting>([\.startedAt], [\.processingStateRaw])
    public var id: UUID = UUID()
    public var title: String = ""
    public var typeRaw: String = MeetingType.general.rawValue
    public var startedAt: Date = Date()
    public var duration: TimeInterval = 0
    public var localeIdentifier: String = "en_AU"
    /// Directory holding the audio chunks, relative to the meetings directory.
    public var audioPath: String = ""
    /// Where the recording started, if the user opted in. Raw coordinates only — no
    /// reverse geocoding, which would be an outbound request (constraint 1).
    public var latitude: Double?
    public var longitude: Double?
    public var processingStateRaw: String = ProcessingState.recording.rawValue
    public var failureMessage: String?
    /// Denormalised title + transcript + summary text, lowercased. See the note above.
    public var searchText: String = ""
    /// v1 relies on a verbal consent process rather than building product around it
    /// (spec 7). This flag records the plain-language acknowledgement shown before
    /// recording; the consent log, badge and share gate are v2 (spec 11.5).
    public var consentAcknowledged: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Segment.meeting)
    public var segments: [Segment] = []

    @Relationship(deleteRule: .cascade, inverse: \Speaker.meeting)
    public var speakers: [Speaker] = []

    @Relationship(deleteRule: .cascade, inverse: \SummaryRecord.meeting)
    public var summary: SummaryRecord?

    public var folder: Folder?

    public init(
        id: UUID = UUID(),
        title: String,
        type: MeetingType,
        startedAt: Date = Date(),
        locale: Locale,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.typeRaw = type.rawValue
        self.startedAt = startedAt
        self.localeIdentifier = locale.identifier
        self.audioPath = id.uuidString
        self.processingStateRaw = ProcessingState.recording.rawValue
        self.searchText = title.lowercased()
        self.latitude = latitude
        self.longitude = longitude
    }

    public var type: MeetingType {
        get { MeetingType(rawValue: typeRaw) ?? .general }
        set { typeRaw = newValue.rawValue }
    }

    public var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .failed }
        set { processingStateRaw = newValue.rawValue }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    public var orderedSegments: [Segment] {
        segments.sorted { $0.start < $1.start }
    }
}

@Model
public final class Segment {
    public var id: UUID = UUID()
    public var start: TimeInterval = 0
    public var end: TimeInterval = 0
    public var text: String = ""
    /// Per-meeting label ("S1"), not a person (spec 4.4).
    public var speakerID: String?
    public var confidence: Double = 1
    public var isFinalized: Bool = true
    /// Set by a manual edit or relabel. Re-running diarization leaves these alone.
    public var editedByUser: Bool = false
    public var meeting: Meeting?

    public init(value: TranscriptSegment) {
        self.id = value.id
        self.start = value.start
        self.end = value.end
        self.text = value.text
        self.speakerID = value.speakerID
        self.confidence = value.confidence
        self.isFinalized = value.isFinalized
        self.editedByUser = value.editedByUser
    }

    public var value: TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: text,
            speakerID: speakerID,
            confidence: confidence,
            isFinalized: isFinalized,
            editedByUser: editedByUser
        )
    }
}

/// A label inside one meeting, not a person. Renaming "S2" to "Dave" here does not
/// carry to the next meeting; that is the v2 speaker registry (spec 11.3).
@Model
public final class Speaker {
    public var id: UUID = UUID()
    public var label: String = ""
    public var displayName: String?
    /// Raw cluster embedding. Unused in v1 and stored deliberately: v2 needs a corpus
    /// to match against, and backfilling embeddings from archived audio is far more
    /// painful than storing them now.
    public var embedding: Data?
    public var meeting: Meeting?

    public init(label: String, displayName: String? = nil, embedding: [Float]? = nil) {
        self.label = label
        self.displayName = displayName
        self.embedding = embedding.map { floats in
            floats.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    public var name: String { displayName ?? label }

    public var embeddingVector: [Float]? {
        guard let embedding else { return nil }
        return embedding.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

@Model
public final class SummaryRecord {
    public var id: UUID = UUID()
    /// The `MeetingSummary` as JSON. Stored whole so a summary schema change does not
    /// need a SwiftData migration for every field.
    public var json: Data = Data()
    public var templateID: UUID?
    public var generatedAt: Date = Date()
    public var meeting: Meeting?

    public init(summary: MeetingSummary, templateID: UUID? = nil) {
        self.json = (try? JSONEncoder().encode(summary)) ?? Data()
        self.templateID = templateID
        self.generatedAt = Date()
    }

    public var summary: MeetingSummary {
        (try? JSONDecoder().decode(MeetingSummary.self, from: json)) ?? MeetingSummary()
    }
}

@Model
public final class Folder {
    public var id: UUID = UUID()
    public var name: String = ""

    @Relationship(inverse: \Meeting.folder)
    public var meetings: [Meeting] = []

    public init(name: String) {
        self.name = name
    }
}
