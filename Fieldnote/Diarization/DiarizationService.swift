import Foundation
import FluidAudio
import OSLog

/// Batch diarization over the accumulated 16 kHz mono buffer, once, on stop
/// (spec 4.2 / 4.4). Apple still ships no diarization API in iOS 27 — the Speech
/// modules are `SpeechTranscriber`, `DictationTranscriber` and `SpeechDetector`
/// (voice activity only) — so this is FluidAudio's CoreML pipeline.
///
/// # Models are bundled, never downloaded
///
/// FluidAudio's convenience path fetches its CoreML models over the network on first
/// use. Fieldnote makes zero outbound requests (constraint 1 and 2), so the models
/// are vendored into the app bundle at build time and loaded from there. If the
/// bundled models are missing this type fails loudly rather than reaching for the
/// network — see `Scripts/vendor-diarization-models.sh` and the README note.
public actor DiarizationService {

    public struct Output: Sendable {
        public var spans: [DiarizedSpan]
        /// One raw embedding per cluster. Dead weight in v1 by design: v2's
        /// cross-meeting matching (spec 11.3) needs a corpus, and backfilling
        /// embeddings from archived audio later is far more painful than storing
        /// them now.
        public var embeddings: [String: [Float]]
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "diarization")
    private var manager: DiarizerManager?

    public init() {}

    public func diarize(
        samples: [Float],
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        guard samples.count > 16_000 else {
            // Under a second of audio. Nothing to cluster.
            return Output(spans: [], embeddings: [:])
        }

        progress(0.05)
        let manager = try await preparedManager()
        progress(0.2)

        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        progress(0.9)

        var spans: [DiarizedSpan] = []
        var embeddings: [String: [Float]] = [:]
        for segment in result.segments {
            let label = Self.label(for: segment.speakerId)
            spans.append(
                DiarizedSpan(
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    speakerID: label,
                    confidence: Double(segment.qualityScore)
                )
            )
            if embeddings[label] == nil {
                embeddings[label] = segment.embedding
            }
        }
        progress(1.0)
        log.notice("Diarized \(spans.count, privacy: .public) spans across \(embeddings.count, privacy: .public) speakers")
        return Output(spans: spans, embeddings: embeddings)
    }

    /// Per-meeting labels only. "S1" is a label in this meeting, not a person, and it
    /// does not carry to the next meeting (spec 4.4).
    static func label(for speakerID: String) -> String {
        let digits = speakerID.filter(\.isNumber)
        return digits.isEmpty ? speakerID : "S\(digits)"
    }

    private func preparedManager() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try DiarizationModelProvider.bundledModels()
        let created = DiarizerManager()
        created.initialize(models: models)
        manager = created
        return created
    }
}

/// Loads the vendored CoreML models from the app bundle.
///
/// SPEC-API — FluidAudio's model-loading entry point moves between releases. This is
/// the one place it is called; pin the package version in `project.yml` and update
/// here when bumping it.
public enum DiarizationModelProvider {

    public enum Failure: Error, LocalizedError {
        case modelsMissing

        public var errorDescription: String? {
            """
            The speaker-identification models are not in the app bundle. Fieldnote \
            does not download them, by design. Rebuild with the models vendored — see \
            Scripts/vendor-diarization-models.sh.
            """
        }
    }

    public static var bundledModelDirectory: URL? {
        Bundle.main.url(forResource: "DiarizationModels", withExtension: nil)
    }

    public static func bundledModels() throws -> DiarizerModels {
        guard let directory = bundledModelDirectory else { throw Failure.modelsMissing }
        return try DiarizerModels.load(from: directory)
    }
}
