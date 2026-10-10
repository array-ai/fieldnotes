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

    /// Every speech model gets the same first 15 minutes: long enough for a steady
    /// rate including load, short enough that the phone doesn't heat up and throttle
    /// the models run last (the whole 68-minute meeting four times did, build 45).
    private let maxAudioSeconds = 900.0
    private let debug = DebugLog.shared

    public init() {}

    public func run(on meeting: MeetingSnapshot, locale: Locale) async {
        guard !isRunning else { return }
        isRunning = true
        rows = []
        // A locked phone would stop the models part-way; keep the screen on.
        ScreenAwake.set(.benchmark, true)
        defer {
            ScreenAwake.set(.benchmark, false)
            isRunning = false
            status = ""
        }

        add("Device", "Fieldnote", DebugLog.appVersion)
        add("Device", "Model", Self.deviceModel())
        add("Device", "iOS", ProcessInfo.processInfo.operatingSystemVersionString)
        add("Device", "Memory", String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1e9))
        add("Device", "Thermal state", Self.thermal(ProcessInfo.processInfo.thermalState))

        // Not alongside a processing run or a model preparing: the memory it takes
        // on top of theirs is how the app ran out (build 41).
        status = "Waiting for other model work to finish…"
        await HeavyModelWork.shared.acquire("the benchmark")
        await benchmarkSpeakers(meeting)
        await benchmarkTranscription(meeting, locale: locale)
        await benchmarkParakeet(meeting, locale: locale)
        await benchmarkNemotronStreaming(meeting, locale: locale)
        await benchmarkSummary(meeting)

        await HeavyModelWork.shared.release()
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
            samples = try AudioSamples(meetingID: meeting.id).slice(0..<Int(maxAudioSeconds * 16_000))
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
        // Whole chunks, up to the same length the other models get.
        var count = 0, total = 0.0
        while count < chunks.count, count == 0 || total + chunks[count].duration <= maxAudioSeconds + 1 {
            total += chunks[count].duration
            count += 1
        }
        let picked = Array(chunks.prefix(count))
        let audioSeconds = picked.reduce(0) { $0 + $1.duration }
        guard audioSeconds > 0 else {
            add("Transcription", "Audio", "no audio chunks stored for this meeting")
            return
        }
        add("Transcription", "Audio", String(format: "first %.1f s, the same for every model", min(meeting.duration, maxAudioSeconds)))
        let service = FileTranscriptionService(locale: locale)
        let started = ContinuousClock.now
        do {
            let segments = try await service.transcribe(chunks: picked)
            let elapsed = seconds(since: started)
            add(
                "Transcription",
                "Apple speech model",
                String(format: "%.1f s of audio in %.2f s (%.0f× real time) · %d line(s)",
                       audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001), segments.count)
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
                    localeIdentifier: locale.identifier,
                    maxSeconds: maxAudioSeconds,
                    // Speech model only: the word checker isn't part of its speed.
                    fixWords: false
                ) { _ in }
                let elapsed = seconds(since: started)
                let audioSeconds = min(meeting.duration, maxAudioSeconds)
                add(
                    "Transcription",
                    name,
                    String(format: "%.1f s of audio in %.2f s (%.0f× real time, including load) · %d line(s)",
                           audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001), lines.count)
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
                localeIdentifier: locale.identifier,
                maxSeconds: maxAudioSeconds
            ) { _ in }
            let elapsed = seconds(since: started)
            let audioSeconds = min(meeting.duration, maxAudioSeconds)
            add(
                "Transcription",
                name,
                String(format: "%.1f s of audio in %.2f s (%.0f× real time, including load) · %d line(s)",
                       audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001), lines.count)
            )
        } catch {
            add("Transcription", name, "failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Summary

    /// Every summary model on the phone, one after another, on the same excerpt:
    /// Apple's, then each downloaded MiniCPM5. Not downloaded ones are listed as such.
    private func benchmarkSummary(_ meeting: MeetingSnapshot) async {
        let lines = meeting.segments.filter { !$0.text.trimmed().isEmpty }
        guard !lines.isEmpty else {
            add("Summary", "Excerpt", "no transcript to summarise")
            return
        }
        // The same text for every model, sized for the smallest window (Apple's):
        // a real part of a meeting, so speeds and results compare like for like.
        let summaryPrompt = SummaryPromptStore.load()
        guard let chunk = await excerpt(lines, prompt: summaryPrompt) else { return }
        add("Summary", "Excerpt", "\(chunk.segments.count) line(s), the same for every model")
        for engine in SummaryEngine.allCases {
            status = "Summary: \(engine.card.title)…"
            if engine.isLocal {
                await benchmarkLocalSummary(engine, chunk: chunk)
            } else {
                await benchmarkAppleSummary(chunk: chunk, summaryPrompt: summaryPrompt)
            }
        }
    }

    /// The first part of the meeting the way real processing sizes it for Apple's
    /// model: whatever fits next to the instructions, the output schema and room for
    /// the answer.
    private func excerpt(_ lines: [TranscriptSegment], prompt summaryPrompt: SummaryPrompt) async -> TranscriptChunk? {
        let fixed = (await OnDeviceModel.tokenCount(instructions: summaryPrompt.instructions, tier: .coreAdvanced) ?? 400)
            + (await OnDeviceModel.tokenCount(schema: DraftChunkNotes.generationSchema, tier: .coreAdvanced) ?? 800)
        let budget = PromptBudget(
            contextSize: OnDeviceModel.contextSize(tier: .coreAdvanced),
            fixedCost: fixed,
            outputReserve: 1_400,
            isMeasured: true
        )
        guard var chunk = TranscriptChunker(budget: budget.chunkBudget, overlap: 0).chunks(from: lines).first else { return nil }
        var prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1, request: summaryPrompt.effectiveRequest)
        while let tokens = await OnDeviceModel.tokenCount(prompt: prompt, tier: .coreAdvanced),
              !budget.fits(promptTokens: tokens), let (half, _) = chunk.halves() {
            chunk = half
            prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1, request: summaryPrompt.effectiveRequest)
        }
        return chunk
    }

    private func benchmarkAppleSummary(chunk: TranscriptChunk, summaryPrompt: SummaryPrompt) async {
        let name = SummaryEngine.apple.card.title
        add("Summary", name, "context window \(OnDeviceModel.contextSize(tier: .coreAdvanced)) tokens")
        let prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1, request: summaryPrompt.effectiveRequest)
        do {
            let session = try OnDeviceModel.appleSession(tier: .coreAdvanced, instructions: summaryPrompt.instructions)
            let started = ContinuousClock.now
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self, contextOptions: OnDeviceModel.contextOptions(local: false))
            let elapsed = seconds(since: started)
            let notes = response.content.notes
            report(name, lines: chunk.segments.count, input: response.usage.input.totalTokenCount,
                   output: response.usage.output.totalTokenCount, elapsed: elapsed, notes: notes)
        } catch {
            add("Summary", name, "failed: \(String(describing: error))")
        }
    }

    private func benchmarkLocalSummary(_ engine: SummaryEngine, chunk: TranscriptChunk) async {
        let name = "\(engine.card.title) (Core AI)"
        let loadStarted = ContinuousClock.now
        let loaded: OnDeviceModel.BenchmarkSession?
        do {
            loaded = try await OnDeviceModel.benchmarkSession(
                for: engine,
                instructions: engine.notesProfile?.format == .markdown ? PlainNotes.markdownInstructions : PlainNotes.instructions
            )
        } catch {
            add("Summary", name, "couldn't load: \(error.localizedDescription)")
            return
        }
        guard let loaded else {
            add("Summary", name, "not downloaded (Settings → Models)")
            return
        }
        defer { loaded.unload() }
        add("Summary", name, String(format: "loaded in %.2f s, context window %d tokens", seconds(since: loadStarted), OnDeviceModel.localContextSize))
        // The model's own notes settings, as processing uses them.
        let profile = engine.notesProfile
        let prompt = profile?.format == .markdown
            ? PlainNotes.markdownPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1)
            : PlainNotes.prompt(chunk: chunk, chunkIndex: 0, chunkCount: 1)
        do {
            let started = ContinuousClock.now
            let response = try await loaded.session.respond(
                to: prompt,
                options: GenerationOptions(temperature: profile?.temperature, maximumResponseTokens: profile?.answerTokens ?? 600),
                contextOptions: OnDeviceModel.contextOptions(local: true)
            )
            let elapsed = seconds(since: started)
            let notes = PlainNotes.parse(response.content, chunk: chunk)
            report(name, lines: chunk.segments.count, input: response.usage.input.totalTokenCount,
                   output: response.usage.output.totalTokenCount, elapsed: elapsed, notes: notes)
            add("Summary", "\(name) answer (start)", String(response.content.prefix(400)))
        } catch {
            add("Summary", name, "failed: \(String(describing: error))")
        }
    }

    private func report(_ name: String, lines: Int, input: Int, output: Int, elapsed: Double, notes: ChunkNotes) {
        add(
            "Summary",
            name,
            String(format: "%d line(s) · %d tokens in, %d out · %.2f s · %.0f output tokens/s · %d topic(s), %d point(s), %d task(s), %d decision(s)",
                   lines, input, output, elapsed, Double(output) / max(elapsed, 0.001),
                   notes.topics.count,
                   notes.topics.reduce(0) { $0 + $1.points.count },
                   notes.actionItems.count,
                   notes.decisions.count)
        )
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
