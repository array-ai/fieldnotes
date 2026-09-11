import AVFoundation
import FieldnoteKit
import Foundation
import OSLog
import Speech

/// A single `SpeechAnalyzer` run: audio in, finalized transcript segments out.
///
/// Used two ways —
/// - live, fed by the recorder's tap while the meeting is happening;
/// - offline, fed by `FileTranscriptionService` from the audio chunks on disk when a
///   live run was lost to an app kill.
///
/// One locale per instance, no mid-stream switching (spec 4.3).
public actor TranscriptionSession {

    public enum Update: Sendable {
        /// Interim text. Show it, never persist it.
        case volatile(String)
        case finalized(TranscriptSegment)
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "speech")
    private let locale: Locale
    private let contextualStrings: [String]
    private let timeOffset: TimeInterval

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var updateContinuation: AsyncStream<Update>.Continuation?

    private(set) public var segments: [TranscriptSegment] = []

    /// - Parameter timeOffset: added to every timestamp, so an offline run over chunk
    ///   3 of a recording still produces times relative to the start of the meeting.
    public init(
        locale: Locale = Locale(identifier: "en_AU"),
        contextualStrings: [String] = MSPVocabulary.contextualStrings,
        timeOffset: TimeInterval = 0
    ) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.timeOffset = timeOffset
    }

    public func updates() -> AsyncStream<Update> {
        // Built with makeStream rather than the closure initialiser: the builder
        // closure is not actor-isolated, so it cannot assign to the stored
        // continuation under strict concurrency.
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        updateContinuation = continuation
        return stream
    }

    public func start() async throws {
        guard analyzer == nil else { return }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        try await SpeechAssetProvisioner.shared.prepare(transcriber: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        applyContextualStrings(to: analyzer)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeResults(from: transcriber)
        }
    }

    public func append(_ audio: CapturedAudio) {
        guard let buffer = audio.makeBuffer() else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the run and returns everything finalized.
    ///
    /// Terminating the input stream is not enough on its own — the session only ends
    /// when a finish method is called or the analyzer is deallocated, and a session
    /// left open holds the model and the locale allocation (spec 4.3).
    @discardableResult
    public func finish() async throws -> [TranscriptSegment] {
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        updateContinuation?.finish()
        updateContinuation = nil
        return segments
    }

    /// Abandons the run without waiting for finalization. Used when a recording is
    /// discarded; the analyzer still has to be finished so the locale is released.
    public func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        transcriber = nil
        updateContinuation?.finish()
        updateContinuation = nil
    }

    // MARK: - Results

    private func consumeResults(from transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmed()
                guard !text.isEmpty else { continue }

                if result.isFinal {
                    let range = Self.timeRange(of: result.text)
                    let segment = TranscriptSegment(
                        start: (range?.start ?? 0) + timeOffset,
                        end: (range?.end ?? 0) + timeOffset,
                        text: text,
                        isFinalized: true
                    )
                    segments.append(segment)
                    updateContinuation?.yield(.finalized(segment))
                } else {
                    updateContinuation?.yield(.volatile(text))
                }
            }
        } catch {
            log.error("Transcription stream ended with error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pulls the audio time range off the attributed result. Every finalized result
    /// carries one because the transcriber was created with `.audioTimeRange`.
    static func timeRange(of text: AttributedString) -> (start: TimeInterval, end: TimeInterval)? {
        var start: TimeInterval?
        var end: TimeInterval?
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let runStart = range.start.seconds
            let runEnd = (range.start + range.duration).seconds
            start = min(start ?? runStart, runStart)
            end = max(end ?? runEnd, runEnd)
        }
        guard let start, let end else { return nil }
        return (start, end)
    }

    // MARK: - Custom vocabulary

    /// Unresolved in iOS 27 (spec 4.3): `contextualStrings` is documented against
    /// `DictationTranscriber`, and reports of its effect on the long-form
    /// `SpeechTranscriber` path range from weak to none.
    ///
    /// It is a few lines, so it is wired up and measured rather than argued about.
    /// If the benchmark shows nothing, the terms stay mangled in v1 and the user
    /// fixes them by hand; the correction layer that would fix it properly is v2
    /// (spec 11.1). Do not build half of that here.
    private func applyContextualStrings(to analyzer: SpeechAnalyzer) {
        guard !contextualStrings.isEmpty else { return }
        let context = AnalysisContext()
        // iOS 27 keys contextual strings by tag rather than taking a flat list.
        // `.general` is the untagged bucket; if tagging turns out to be what makes
        // this work on the long-form path, that is exactly what the spec 4.3
        // benchmark should compare.
        context.contextualStrings = [.general: contextualStrings]
        Task { try? await analyzer.setContext(context) }
    }
}
