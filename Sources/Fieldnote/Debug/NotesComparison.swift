import FieldnoteKit
import Foundation
import Observation

/// Debug mode: writes one meeting's notes with every notes model on the phone, one
/// after another, the way real processing does (every part, the overview, the
/// citation checks), and collects them into one Markdown report to share for
/// comparing quality. The meeting itself is never changed.
///
/// The benchmark times each model on one excerpt; this is the whole meeting, so it
/// shows what each model actually produces, at the cost of taking minutes per model.
@MainActor
@Observable
public final class NotesComparison {

    public struct Result: Identifiable, Sendable {
        public let id = UUID()
        public var engine: SummaryEngine
        /// What actually ran: a chosen model that can't load falls back to Apple's.
        public var ranOn: String?
        public var seconds: Double?
        /// The phone's thermal state when this model started and finished. A hot
        /// phone throttles, so a model run late in the comparison can look slower than
        /// it is.
        public var thermal = ""
        public var summary: MeetingSummary?
        public var error: String?

        public var line: String {
            if let error { return error }
            guard let summary, let seconds else { return "" }
            let topics = summary.topics ?? []
            let points = topics.reduce(0) { $0 + $1.points.count }
            return String(format: "%.0f s · ", seconds)
                + "\(topics.count) topic(s), \(points) point(s), \(summary.actionItems.count) task(s), "
                + "\(summary.decisions.count) decision(s), \(summary.openQuestions.count) question(s)"
        }
    }

    public private(set) var results: [Result] = []
    public private(set) var isRunning = false
    public private(set) var status = ""
    /// The Markdown report, once a run has finished.
    public private(set) var reportURL: URL?

    private let debug = DebugLog.shared

    public init() {}

    public func run(on meeting: MeetingSnapshot, includeTranscript: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        results = []
        reportURL = nil
        // A locked phone would stop the models part-way; keep the screen on.
        ScreenAwake.set(.benchmark, true)
        defer {
            OnDeviceModel.overrideEngine(nil)
            ScreenAwake.set(.benchmark, false)
            isRunning = false
            status = ""
        }

        // Not alongside processing or a model preparing: two notes models at once
        // run the phone out of memory (build 41).
        status = "Waiting for other model work to finish…"
        await HeavyModelWork.shared.acquire("the notes comparison")
        debug.log("compare", "\(DebugLog.short(meeting.id)): writing notes with every model, \(meeting.segments.count) lines")

        let context = SummarizationService.MeetingContext(id: meeting.id, title: meeting.title, date: meeting.startedAt)
        for engine in SummaryEngine.allCases {
            guard OnDeviceModel.isAvailable(engine) else {
                results.append(Result(engine: engine, error: "not downloaded (Settings → Models)"))
                continue
            }
            // Models run back to back, so each inherits the heat of the ones before;
            // wait for the phone to cool to a fair start (a throttled run made Qwen3.5
            // 2B look far slower, build 63).
            await coolDown(before: engine)
            let thermalAtStart = ModelBenchmark.thermal(ProcessInfo.processInfo.thermalState)
            status = "\(engine.card.title)…"
            OnDeviceModel.overrideEngine(engine)
            _ = OnDeviceModel.takeEngineUsed()
            let started = ContinuousClock.now
            do {
                // A new service each time: its prompt and model are set per run.
                let summary = try await SummarizationService().summarise(
                    segments: meeting.segments,
                    meeting: context,
                    allowDeferral: false
                )
                let elapsed = started.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                var result = Result(engine: engine, ranOn: OnDeviceModel.takeEngineUsed()?.card.title, seconds: seconds)
                result.thermal = "\(thermalAtStart) → \(ModelBenchmark.thermal(ProcessInfo.processInfo.thermalState))"
                result.summary = summary.applyingSpeakerNames(meeting.speakerNames)
                results.append(result)
                debug.log("compare", "\(engine.card.title): \(result.line)")
            } catch let notWritten as SummarizationService.NotWritten {
                // The detail, not the user-facing "busy or limited": this is for
                // finding out why.
                results.append(Result(engine: engine, error: "failed: \(notWritten.detail.prefix(200))"))
                debug.log("compare", "\(engine.card.title): failed: \(notWritten.detail)")
            } catch {
                results.append(Result(engine: engine, error: "failed: \(error.localizedDescription)"))
                debug.log("compare", "\(engine.card.title): failed: \(error)")
            }
        }
        OnDeviceModel.overrideEngine(nil)
        await HeavyModelWork.shared.release()

        reportURL = writeReport(meeting: meeting, includeTranscript: includeTranscript)
    }

    /// Waits, up to ten minutes, while the phone reports serious or critical heat.
    private func coolDown(before engine: SummaryEngine) async {
        let started = ContinuousClock.now
        while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
              started.duration(to: .now) < .seconds(600), !Task.isCancelled {
            status = "Letting the phone cool before \(engine.card.title)…"
            try? await Task.sleep(for: .seconds(15))
        }
        let waited = started.duration(to: .now)
        if waited > .seconds(1) {
            debug.log("compare", "waited \(waited.components.seconds) s for the phone to cool before \(engine.card.title); now \(ModelBenchmark.thermal(ProcessInfo.processInfo.thermalState))")
        }
    }

    // MARK: - Report

    private func writeReport(meeting: MeetingSnapshot, includeTranscript: Bool) -> URL? {
        let renderer = MarkdownRenderer()
        var lines = [
            "# Notes comparison: \(meeting.title)",
            "",
            "- Fieldnote \(DebugLog.appVersion), \(ModelBenchmark.deviceModel()), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- Meeting: \(Timecode.short(meeting.duration)), \(meeting.segments.count) transcript lines",
            "- Same transcript for every model; Settings' summary prompt and small-talk setting apply to all.",
            "- Before each model the phone is left to cool (up to 10 minutes) if it reports serious or critical heat; a hot phone runs slower.",
            "",
            "| Model | Ran on | Thermal state | Result |",
            "|---|---|---|---|",
        ]
        for result in results {
            lines.append("| \(result.engine.card.title) | \(result.ranOn ?? "–") | \(result.thermal.isEmpty ? "–" : result.thermal) | \(result.line) |")
        }
        for result in results {
            guard let summary = result.summary else { continue }
            var snapshot = meeting
            snapshot.summary = summary
            lines += ["", "---", "", "## \(result.engine.card.title)", "", result.line, "", renderer.renderSummary(snapshot)]
        }
        if includeTranscript {
            lines += ["", "---", "", "## Transcript", "", renderer.renderTranscript(meeting)]
        }

        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fieldnote notes comparison \(stamp).md")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FieldnoteStorage.protect(url)
            return url
        } catch {
            debug.log("compare", "couldn't write the report: \(error)")
            return nil
        }
    }
}
