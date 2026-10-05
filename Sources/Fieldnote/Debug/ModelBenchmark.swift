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

        add("Device", "Model", Self.deviceModel())
        add("Device", "iOS", ProcessInfo.processInfo.operatingSystemVersionString)
        add("Device", "Memory", String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1e9))
        add("Device", "Thermal state", Self.thermal(ProcessInfo.processInfo.thermalState))

        await benchmarkSpeakers(meeting)
        await benchmarkTranscription(meeting, locale: locale)
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
                    String(format: "load %.2f s cold / %.2f s warm · run %.2f s (%.0f× real time) · %d speaker(s)",
                           coldTime, warmTime, runTime, audioSeconds / max(runTime, 0.001), speakers)
                )
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
                String(format: "%.1f s of audio in %.2f s (%.0f× real time) · %d line(s)",
                       first.duration, elapsed, first.duration / max(elapsed, 0.001), segments.count)
            )
        } catch {
            add("Transcription", "Apple speech model", "failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Summary

    private func benchmarkSummary(_ meeting: MeetingSnapshot) async {
        status = "Summary model…"
        add("Summary", "Context window", "\(OnDeviceModel.contextSize(tier: .coreAdvanced)) tokens")

        let lines = meeting.segments.filter { !$0.text.trimmed().isEmpty }
        guard !lines.isEmpty else {
            add("Summary", "Excerpt", "no transcript to summarise")
            return
        }
        // One excerpt of about a third of the context, the size real chunks are.
        let chunker = TranscriptChunker(budget: 1_200, overlap: 0)
        guard let chunk = chunker.chunks(from: lines).first else { return }
        let prompt = PromptTemplates.chunkPrompt(chunk: chunk, chunkIndex: 0, chunkCount: 1)
        let promptTokens = await OnDeviceModel.tokenCount(prompt: prompt, tier: .coreAdvanced)

        do {
            let session = try OnDeviceModel.session(tier: .coreAdvanced, instructions: PromptTemplates.instructions)
            let started = ContinuousClock.now
            let response = try await session.respond(to: prompt, generating: DraftChunkNotes.self)
            let elapsed = seconds(since: started)
            let notes = response.content
            let outputTokens = await OnDeviceModel.tokenCount(
                prompt: String(describing: notes.topics.map(\.title)) + notes.topics.flatMap(\.points).map(\.text).joined(separator: " "),
                tier: .coreAdvanced
            )
            add(
                "Summary",
                "One excerpt",
                String(format: "%d line(s), %@ prompt tokens · %.2f s · %d topic(s)%@",
                       chunk.segments.count,
                       promptTokens.map(String.init) ?? "?",
                       elapsed,
                       notes.topics.count,
                       outputTokens.map { String(format: " · ~%.0f output tokens/s", Double($0) / max(elapsed, 0.001)) } ?? "")
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
