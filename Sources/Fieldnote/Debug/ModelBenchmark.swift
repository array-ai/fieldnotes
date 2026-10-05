import FieldnoteKit
import Foundation
import FoundationModels
import Observation

/// Debug mode: times every on-device model against one of the user's own
/// recordings, on this phone. Speed only — accuracy needs a human reading the output.
///
/// For each speaker-identification method: a cold load (models dropped first, so
/// CoreML compiles them), a warm load, and processing time over the audio. Then
/// Apple's speech model on the first audio chunk, and the summary model on one
/// excerpt of the transcript.
@MainActor
@Observable
public final class ModelBenchmark {

    public struct Row: Identifiable, Sendable {
        public let id = UUID()
        public var section: String
        public var name: String
        public var value: String
    }

    public private(set) var rows: [Row] = []
    public private(set) var isRunning = false
    public private(set) var status = ""

    /// Capped so a three-hour meeting doesn't turn the benchmark into a three-hour job.
    private let maxAudioSeconds = 300.0
    private let debug = DebugLog.shared

    public init() {}

    public func run(on meeting: MeetingSnapshot, locale: Locale) async {
        guard !isRunning else { return }
        isRunning = true
        rows = []
        defer {
            isRunning = false
            status = ""
        }

        add("Device", "Fieldnote", DebugLog.appVersion)
        add("Device", "Model", Self.deviceModel())
        add("Device", "iOS", ProcessInfo.processInfo.operatingSystemVersionString)
        add("Device", "Memory", String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1e9))
        add("Device", "Thermal state", Self.thermal(ProcessInfo.processInfo.thermalState))

        await benchmarkSpeakers(meeting)
        await benchmarkTranscription(meeting, locale: locale)
        await benchmarkParakeet(meeting, locale: locale)
        await benchmarkNemotronStreaming(meeting, locale: locale)
        await benchmarkSummary(meeting)

        add("Device", "Thermal state after", Self.thermal(ProcessInfo.processInfo.thermalState))
        debug.log("benchmark", "finished:\n" + report)
    }

    /// Plain text, for sharing.
    public var report: String {
        var lines: [String] = []
        var section = ""
        for row in rows {
            if row.section != section {
                section = row.section
                lines.append("\n[\(section)]")
            }
            lines.append("\(row.name): \(row.value)")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Speakers

    private func benchmarkSpeakers(_ meeting: MeetingSnapshot) async {
        status = "Reading audio…"
        let samples: [Float]
        do {
            let buffer = try DiarizationBuffer(meetingID: meeting.id)
            let all = try await buffer.samples()
            samples = Array(all.prefix(Int(maxAudioSeconds * 16_000)))
        } catch {
            add("Speakers", "Audio", "couldn't read: \(error.localizedDescription)")
            return
        }
        let audioSeconds = Double(samples.count) / 16_000
        guard audioSeconds >= 2 else {
            add("Speakers", "Audio", "no speaker audio stored for this meeting")
            return
        }
        add("Speakers", "Audio", String(format: "%.1f s", audioSeconds))

        let service = DiarizationService.shared
        for method in DiarizationMethod.allCases {
            guard method.isInstalled else {
                add("Speakers", method.displayName, "not downloaded (Settings → Models)")
                continue
            }
            status = "Speakers: \(method.displayName)…"
            await service.unload(method)
            let cold = ContinuousClock.now
            await service.prewarm(method)
            let coldTime = seconds(since: cold)
            guard await service.isLoaded(method) else {
                add("Speakers", method.displayName, "models failed to load (see Activity log)")
                continue
            }
            let warm = ContinuousClock.now
            await service.prewarm(method)
            let warmTime = seconds(since: warm)

            let run = ContinuousClock.now
            do {
                let output = try await service.diarize(samples: samples, method: method)
                let runTime = seconds(since: run)
                let speakers = Set(output.spans.map(\.speakerID)).count
                add(
                    "Speakers",
                    method.displayName,
                    String(format: "%@load %.2f s cold / %.2f s warm · run %.2f s (%.0f× real time) · %d speaker(s)",
                           method == .nemotron3 ? "Neural Engine: " : "",
                           coldTime, warmTime, runTime, audioSeconds / max(runTime, 0.001), speakers)
                )
                if method == .nemotron3 {
                    let cpuLoad = try await service.timeCPULoad()
                    let cpu = try await service.benchmarkNemotronOnCPU(samples)
                    add(
                        "Speakers",
                        "Nemotron 3 on CPU",
                        String(format: "load %.2f s · run %.2f s (%.0f× real time) · %d speaker(s). Used while the Neural Engine model compiles.",
                               cpuLoad, cpu.seconds, audioSeconds / max(cpu.seconds, 0.001), cpu.speakers)
                    )
                }
            } catch {
                add("Speakers", method.displayName, "failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transcription

    private func benchmarkTranscription(_ meeting: MeetingSnapshot, locale: Locale) async {
        status = "Transcription…"
        let chunks = ChunkedAudioWriter.existingChunks(in: FieldnoteStorage.audioChunkDirectory(for: meeting.id))
        guard let first = chunks.first, first.duration > 0 else {
            add("Transcription", "Audio", "no audio chunks stored for this meeting")
            return
        }
        let service = FileTranscriptionService(locale: locale)
        let started = ContinuousClock.now
        do {
            let segments = try await service.transcribe(chunks: [first])
            let elapsed = seconds(since: started)
            add(
                "Transcription",
                "Apple speech model",
                String(format: "first %.1f s of audio in %.2f s (%.0f× real time) · %d line(s)",
                       first.duration, elapsed, first.duration / max(elapsed, 0.001), segments.count)
            )
        } catch {
            add("Transcription", "Apple speech model", "failed: \(error.localizedDescription)")
        }
    }

    private func benchmarkParakeet(_ meeting: MeetingSnapshot, locale: Locale) async {
        for engine in TranscriptionEngine.allCases where engine != .apple && engine != .nemotronStreaming {
            let name = engine.card.title
            guard let pack = engine.modelPack, ModelDownloads.installedDirectory(for: pack) != nil else {
                add("Transcription", name, "not downloaded (Settings → Models)")
                continue
            }
            guard engine.supports(locale.identifier) else {
                add("Transcription", name, "doesn't support this language")
                continue
            }
            status = "Transcription: \(name)…"
            let started = ContinuousClock.now
            do {
                let lines = try await ParakeetTranscriber.transcribe(
                    engine: engine,
                    meetingID: meeting.id,
                    localeIdentifier: locale.identifier
                ) { _ in }
                let elapsed = seconds(since: started)
                add(
                    "Transcription",
                    name,
                    String(format: "whole meeting, %.1f s of audio in %.2f s (%.0f× real time, including load) · %d line(s)",
                           meeting.duration, elapsed, meeting.duration / max(elapsed, 0.001), lines.count)
                )
            } catch {
                add("Transcription", name, "failed: \(error.localizedDescription)")
            }
        }
    }

    private func benchmarkNemotronStreaming(_ meeting: MeetingSnapshot, locale: Locale) async {
        let name = TranscriptionEngine.nemotronStreaming.card.title
        guard NemotronStreamingTranscriber.modelDirectory() != nil else {
            add("Transcription", name, "not downloaded (Settings → Models)")
            return
        }
        guard TranscriptionEngine.nemotronStreaming.supports(locale.identifier) else {
            add("Transcription", name, "doesn't support this language")
            return
        }
        status = "Transcription: \(name)…"
        let started = ContinuousClock.now
        do {
            let lines = try await NemotronStreamingTranscriber.transcribe(
                meetingID: meeting.id,
                localeIdentifier: locale.identifier
            ) { _ in }
            let elapsed = seconds(since: started)
            add(
                "Transcription",
                name,
                String(format: "whole meeting, %.1f s of audio in %.2f s (%.0f× real time, including load) · %d line(s)",
                       meeting.duration, elapsed, meeting.duration / max(elapsed, 0.001), lines.count)
            )
        } catch {
            add("Transcription", name, "failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Summary

    private func benchmarkSummary(_ meeting: MeetingSnapshot) async {
        status = "Summary model…"
        do {
            try await OnDeviceModel.prepareSummaryModel()
        } catch {
            add("Summary", "Model", "couldn't load: \(error.localizedDescription)")
            return
        }
        defer { OnDeviceModel.releaseSummaryModel() }
        let local = OnDeviceModel.usesLocalModel
        add("Summary", "Model", local ? "Qwen3 1.7B (Core AI)" : "Apple's on-device model")
        add("Summary", "Context window", "\(local ? OnDeviceModel.localContextSize : OnDeviceModel.contextSize(tier: .coreAdvanced)) tokens")

        let lines = meeting.segments.filter { !$0.text.trimmed().isEmpty }
        guard !lines.isEmpty else {
            add("Summary", "Excerpt", "no transcript to summarise")
            return
        }
        // One excerpt sized the way real processing sizes it: whatever fits next to
        // the instructions, the output schema and room for the answer.
        let summaryPrompt = SummaryPromptStore.load()
        let fixed = (await OnDeviceModel.tokenCount(instructions: summaryPrompt.instructions, tier: .coreAdvanced) ?? 400)
            + (await OnDeviceModel.tokenCount(schema: DraftChunkNotes.generationSchema, tier: .coreAdvanced) ?? 800)
        let budget = PromptBudget(
            contextSize: OnDeviceModel.contextSize(tier: .coreAdvanced),
            fixedCost: fixed,
            outputReserve: 1_400,
            isMeasured: true
        )
        guard var chunk = TranscriptChunker(budget: budget.chunkBudget, overlap: 0).chunks(from: lines).first else { return }
        var prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1, request: summaryPrompt.effectiveRequest)
        while let tokens = await OnDeviceModel.tokenCount(prompt: prompt, tier: .coreAdvanced),
              !budget.fits(promptTokens: tokens), let (half, _) = chunk.halves() {
            chunk = half
            prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1, request: summaryPrompt.effectiveRequest)
        }
        let promptTokens = await OnDeviceModel.tokenCount(prompt: prompt, tier: .coreAdvanced)

        do {
            let session = try OnDeviceModel.session(tier: .coreAdvanced, instructions: summaryPrompt.instructions)
            let started = ContinuousClock.now
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self, contextOptions: OnDeviceModel.contextOptions)
            let elapsed = seconds(since: started)
            let notes = response.content
            let input = response.usage.input.totalTokenCount
            let output = response.usage.output.totalTokenCount
            add(
                "Summary",
                "One excerpt",
                String(format: "%d line(s) · %d tokens in (prompt %@), %d out · %.2f s · %.0f output tokens/s · %d topic(s)",
                       chunk.segments.count,
                       input,
                       promptTokens.map(String.init) ?? "?",
                       output,
                       elapsed,
                       Double(output) / max(elapsed, 0.001),
                       notes.topics.count)
            )
        } catch {
            add("Summary", "One excerpt", "failed: \(String(describing: error))")
        }
    }

    // MARK: - Helpers

    private func add(_ section: String, _ name: String, _ value: String) {
        rows.append(Row(section: section, name: name, value: value))
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
