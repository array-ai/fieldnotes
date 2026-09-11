import AVFoundation
import FieldnoteKit
import Foundation
import OSLog
import Observation

/// Runs a recording: one capture, three consumers.
///
/// ```
/// mic ──┬── TranscriptionSession (SpeechAnalyzer) → live transcript
///       ├── ChunkedAudioWriter                    → m4a chunks on disk
///       └── DiarizationBuffer                     → 16 kHz mono for the stop-time pass
/// ```
///
/// Buffers leave the tap through an `AsyncStream` rather than being handed straight
/// to actors: the tap callback runs on the audio render thread, where allocating,
/// awaiting, or blocking produces dropouts that look like a hardware fault.
@MainActor
@Observable
public final class RecordingController {

    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case recording
        case paused
        case interrupted
        case stopping
        case failed(String)
    }

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "recording")

    public private(set) var state: State = .idle
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var level: Double = 0
    public private(set) var volatileText: String = ""
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var meetingID: UUID?

    private let engine = AVAudioEngine()
    #if os(iOS)
    private let sessionController = AudioSessionController()
    #endif
    private var writer: ChunkedAudioWriter?
    private var diarizationBuffer: DiarizationBuffer?
    private var transcription: TranscriptionSession?
    private var pump: Task<Void, Never>?
    private var updates: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var liveActivity: RecordingActivityController?
    private var startDate = Date()
    private var accumulated: TimeInterval = 0
    private var locale: Locale = Locale(identifier: "en_AU")

    public init() {}

    /// True whenever a recording is in flight, including paused and interrupted.
    public var isActive: Bool {
        switch state {
        case .idle, .failed: false
        case .preparing, .recording, .paused, .interrupted, .stopping: true
        }
    }

    // MARK: - Lifecycle

    public func start(meetingID: UUID, title: String, type: MeetingType, locale: Locale) async throws {
        guard !isActive else { return }
        state = .preparing
        self.meetingID = meetingID
        self.locale = locale

        #if os(iOS)
        guard await sessionController.requestPermission() else {
            state = .failed("Microphone access is off for Fieldnote.")
            throw RecordingError.microphoneDenied
        }
        sessionController.onEvent = { [weak self] event in
            self?.handle(event)
        }
        try sessionController.activate()
        #endif

        writer = try ChunkedAudioWriter(meetingID: meetingID)
        diarizationBuffer = try DiarizationBuffer(meetingID: meetingID)

        let transcription = TranscriptionSession(locale: locale)
        self.transcription = transcription
        try await transcription.start()
        observe(transcription)

        startPump()
        try installTapAndStart()

        startDate = Date()
        accumulated = 0
        state = .recording

        liveActivity = RecordingActivityController(meetingID: meetingID, title: title, type: type)
        await liveActivity?.start(startedAt: startDate)
    }

    public func pause() async {
        guard state == .recording else { return }
        engine.pause()
        accumulated += Date().timeIntervalSince(startDate)
        try? await writer?.flush()
        state = .paused
        await liveActivity?.update(elapsed: elapsed, level: 0, isPaused: true)
    }

    public func resume() async {
        guard state == .paused || state == .interrupted else { return }
        do {
            #if os(iOS)
            try sessionController.activate()
            #endif
            try engine.start()
            startDate = Date()
            state = .recording
            await liveActivity?.update(elapsed: elapsed, level: level, isPaused: false)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Ends capture and returns what was captured. Everything from here is the
    /// pipeline's problem (spec 4.7) — this method must not do minutes of work.
    @discardableResult
    public func stop() async -> RecordingResult? {
        guard let meetingID, state != .idle else { return nil }
        state = .stopping
        if engine.isRunning {
            accumulated += Date().timeIntervalSince(startDate)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        await pump?.value
        pump = nil
        updates?.cancel()
        updates = nil

        let chunks = (try? await writer?.finish()) ?? []
        try? await diarizationBuffer?.close()
        let liveSegments = (try? await transcription?.finish()) ?? []
        transcription = nil

        #if os(iOS)
        sessionController.deactivate()
        #endif
        await liveActivity?.end()
        liveActivity = nil

        segments = liveSegments
        state = .idle
        let duration = accumulated

        return RecordingResult(
            meetingID: meetingID,
            chunks: chunks,
            liveSegments: liveSegments,
            duration: duration,
            locale: locale
        )
    }

    // MARK: - Capture

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecordingError.noInput }

        let continuation = bufferContinuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Audio render thread. Copy, hand off, return. Nothing else.
            guard let copy = buffer.deepCopy() else { return }
            continuation?.yield(copy)
        }
        engine.prepare()
        try engine.start()
    }

    private func startPump() {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        bufferContinuation = continuation

        let writer = writer
        let diarization = diarizationBuffer
        let transcription = transcription

        pump = Task { [weak self] in
            for await buffer in stream {
                do {
                    try await writer?.write(buffer)
                    try await diarization?.append(buffer)
                } catch {
                    self?.recordFailure(error)
                }
                await transcription?.append(buffer)

                // This task inherits the type's main-actor isolation, so these are
                // plain assignments — a MainActor.run hop here would be a no-op with
                // a cost. The writes above still hop to their own actors, which is
                // where the file I/O belongs.
                guard let self else { continue }
                // Smooth the meter so it reads as a level, not a strobe.
                self.level = self.level * 0.7 + buffer.peakLevel * 0.3
                self.elapsed = self.currentElapsed
            }
        }
    }

    private func observe(_ session: TranscriptionSession) {
        updates = Task { [weak self] in
            for await update in await session.updates() {
                guard let self else { return }
                switch update {
                case .volatile(let text):
                    self.volatileText = text
                case .finalized(let segment):
                    self.volatileText = ""
                    self.segments.append(segment)
                }
            }
        }
    }

    private var currentElapsed: TimeInterval {
        state == .recording ? accumulated + Date().timeIntervalSince(startDate) : accumulated
    }

    public var elapsedNow: TimeInterval { currentElapsed }

    private func recordFailure(_ error: Error) {
        log.error("Recording write failed: \(error.localizedDescription, privacy: .public)")
        state = .failed(error.localizedDescription)
    }

    // MARK: - Interruptions

    #if os(iOS)
    private func handle(_ event: AudioSessionController.Event) {
        switch event {
        case .interruptionBegan:
            // Finalise what is in flight rather than dropping it (spec 4.1).
            Task {
                engine.pause()
                accumulated += Date().timeIntervalSince(startDate)
                try? await writer?.flush()
                try? await diarizationBuffer?.flush()
                state = .interrupted
                await liveActivity?.update(elapsed: elapsed, level: 0, isPaused: true)
            }
        case .interruptionEnded(let shouldResume):
            guard shouldResume else { return }
            Task { await resume() }
        case .routeChanged(let reason):
            log.notice("Route changed: \(reason.rawValue, privacy: .public)")
            // A new mic means a new input format; restart the tap on the new one.
            guard state == .recording else { return }
            Task {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                do { try installTapAndStart() } catch { recordFailure(error) }
            }
        case .mediaServicesReset:
            recordFailure("Audio services restarted. The recording so far is saved.")
        }
    }

    private func recordFailure(_ message: String) {
        log.error("\(message, privacy: .public)")
        state = .failed(message)
    }
    #endif
}

public struct RecordingResult: Sendable {
    public var meetingID: UUID
    public var chunks: [ChunkedAudioWriter.Chunk]
    public var liveSegments: [TranscriptSegment]
    public var duration: TimeInterval
    public var locale: Locale
}

public enum RecordingError: Error, LocalizedError {
    case microphoneDenied
    case noInput

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Fieldnote needs microphone access to record."
        case .noInput: "No audio input is available."
        }
    }
}
