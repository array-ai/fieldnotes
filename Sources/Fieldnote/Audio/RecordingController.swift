import AVFoundation
import FieldnoteKit
import Foundation
import OSLog
import Observation
import Synchronization

/// Runs a recording: one capture, three consumers.
///
/// ```
/// mic ──┬── TranscriptionSession (SpeechAnalyzer) → live transcript
///       ├── ChunkedAudioWriter                    → m4a chunks on disk
///       └── DiarizationBuffer                     → 16 kHz mono for the stop-time pass
///                 └── NemotronStreamingTranscriber → live transcript, if chosen
/// ```
///
/// With Nemotron 3.5 Streaming chosen, it writes the live transcript instead of
/// Apple's model; the two never run together.
///
/// Buffers leave the tap through an `AsyncStream` rather than being handed straight
/// to actors: the tap callback runs on the audio render thread, where allocating,
/// awaiting, or blocking produces dropouts that look like a hardware fault.
///
/// Two loops, so a slow model never costs recorded audio: the first only saves to
/// disk (the m4a chunks and the 16 kHz buffer) and hands each piece on; the second
/// feeds the live transcript and live speakers, and may fall behind. If it falls so
/// far behind that audio is dropped, the live results are thrown away at stop and
/// the pipeline works from the saved audio instead.
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
    /// Speakers identified so far, when live identification is on. Lags the audio
    /// by the model's window (about ten seconds).
    public private(set) var liveSpans: [DiarizedSpan] = []
    public private(set) var identifiesSpeakersLive = false

    private let engine = AVAudioEngine()
    #if os(iOS)
    private let sessionController = AudioSessionController()
    #endif
    private var writer: ChunkedAudioWriter?
    private var diarizationBuffer: DiarizationBuffer?
    private var transcription: TranscriptionSession?
    private var nemotron: NemotronStreamingTranscriber?
    private var pump: Task<Void, Never>?
    private var livePump: Task<Void, Never>?
    private var liveContinuation: AsyncStream<LiveAudio>.Continuation?
    private let drops = DropCounter()
    private var engineObserver: NSObjectProtocol?
    private var updates: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var liveActivity: RecordingActivityController?
    private var startDate = Date()
    private var accumulated: TimeInterval = 0
    private var locale: Locale = Locale(identifier: "en_AU")

    public init() {}

    /// True whenever a recording is in flight, including paused and interrupted.
    ///
    /// A failed recording is still active: the audio so far is on disk, and Stop
    /// saves and processes it.
    public var isActive: Bool {
        switch state {
        case .idle: false
        case .preparing, .recording, .paused, .interrupted, .stopping, .failed: true
        }
    }

    // MARK: - Lifecycle

    public func start(
        meetingID: UUID,
        title: String,
        type: MeetingType,
        locale: Locale,
        identifySpeakersLive: Bool = false
    ) async throws {
        guard !isActive else { return }
        state = .preparing
        self.meetingID = meetingID
        self.locale = locale
        liveSpans = []
        identifiesSpeakersLive = false
        do {
            try await begin(meetingID: meetingID, title: title, type: type, locale: locale, identifySpeakersLive: identifySpeakersLive)
        } catch {
            // Nothing was captured: back to idle (not failed, which means "audio
            // saved, tap Save"). The caller shows the error.
            DebugLog.shared.log("recording", "\(DebugLog.short(meetingID)): couldn't start: \(error)")
            await abandonStart()
            throw error
        }
    }

    private func begin(
        meetingID: UUID,
        title: String,
        type: MeetingType,
        locale: Locale,
        identifySpeakersLive: Bool
    ) async throws {
        #if os(iOS)
        guard await sessionController.requestPermission() else {
            throw RecordingError.microphoneDenied
        }
        sessionController.onEvent = { [weak self] event in
            self?.handle(event)
        }
        try sessionController.activate()
        #endif

        writer = try ChunkedAudioWriter(meetingID: meetingID)
        diarizationBuffer = try DiarizationBuffer(meetingID: meetingID)

        if NemotronStreamingTranscriber.isSelected(for: locale.identifier) {
            let nemotron = NemotronStreamingTranscriber { [weak self] lines in
                Task { @MainActor in self?.showNemotronLines(lines) }
            }
            await nemotron.begin(localeIdentifier: locale.identifier)
            self.nemotron = nemotron
            DebugLog.shared.log("recording", "\(DebugLog.short(meetingID)): live transcript by nemotronStreaming")
        } else {
            let transcription = TranscriptionSession(locale: locale)
            self.transcription = transcription
            try await transcription.start()
            observe(transcription)
        }

        if identifySpeakersLive {
            // Returns at once: audio queues until a model is ready, so pressing
            // record never waits on a model load.
            await DiarizationService.shared.beginLive()
            identifiesSpeakersLive = true
        }

        drops.reset()
        startPump()
        observeEngineConfiguration()
        try installTapAndStart()

        startDate = Date()
        accumulated = 0
        state = .recording

        liveActivity = RecordingActivityController(meetingID: meetingID, title: title, type: type)
        await liveActivity?.start(startedAt: startDate)
    }

    private func abandonStart() async {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        // Only if capture got that far: touching the input node creates it, which
        // isn't wanted after a refused microphone.
        if pump != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        bufferContinuation?.finish()
        bufferContinuation = nil
        await pump?.value
        pump = nil
        liveContinuation?.finish()
        liveContinuation = nil
        await livePump?.value
        livePump = nil
        updates?.cancel()
        updates = nil
        await transcription?.cancel()
        transcription = nil
        _ = await nemotron?.finish()
        nemotron = nil
        if identifiesSpeakersLive {
            await DiarizationService.shared.cancelLive()
            identifiesSpeakersLive = false
        }
        _ = try? await writer?.finish()
        writer = nil
        try? await diarizationBuffer?.close()
        diarizationBuffer = nil
        #if os(iOS)
        sessionController.deactivate()
        #endif
        meetingID = nil
        state = .idle
    }

    public func pause() async {
        guard state == .recording else { return }
        engine.pause()
        accumulated += Date().timeIntervalSince(startDate)
        try? await writer?.flush()
        state = .paused
        DebugLog.shared.log("recording", "paused")
        await liveActivity?.update(elapsed: elapsed, level: 0, isPaused: true)
    }

    public func resume() async {
        guard state == .paused || state == .interrupted else { return }
        do {
            #if os(iOS)
            try sessionController.activate()
            #endif
            // Re-reads the input format: the mic may have changed while paused (a
            // headset connected during a call), and starting the engine with the old
            // format raises an exception Swift can't catch.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try installTapAndStart()
            startDate = Date()
            state = .recording
            DebugLog.shared.log("recording", "resumed")
            await liveActivity?.update(elapsed: elapsed, level: level, isPaused: false)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Ends capture and returns what was captured. Everything from here is the
    /// pipeline's problem (spec 4.7) — this method must not do minutes of work.
    @discardableResult
    public func stop() async -> RecordingResult? {
        guard let meetingID, state != .idle, state != .stopping else { return nil }
        // By state, not engine.isRunning: an engine iOS stopped on its own would
        // otherwise leave the time since the last start uncounted.
        if state == .recording {
            accumulated += Date().timeIntervalSince(startDate)
        }
        state = .stopping
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        await pump?.value
        pump = nil
        // Stop mustn't wait minutes for a model to catch up: past ~10 s of backlog
        // the live results are given up and redone from the saved audio.
        if drops.queuedLive > 120 { drops.skipLiveBacklog() }
        liveContinuation?.finish()
        await livePump?.value
        livePump = nil
        updates?.cancel()
        updates = nil

        let chunks = (try? await writer?.finish()) ?? []
        try? await diarizationBuffer?.close()
        let dropped = drops.counts
        if dropped.saved > 0 {
            DebugLog.shared.log("recording", "\(DebugLog.short(meetingID)): \(dropped.saved) piece(s) of audio were dropped before they could be saved")
        }
        // Live results with gaps: the pipeline redoes both from the saved audio.
        let liveIncomplete = dropped.live > 0
        if liveIncomplete {
            DebugLog.shared.log("recording", "\(DebugLog.short(meetingID)): live transcript and speakers fell behind (\(dropped.live) piece(s) skipped); they'll be redone from the saved audio")
        }
        var liveSpeakerSpans: [DiarizedSpan]?
        if identifiesSpeakersLive {
            do {
                liveSpeakerSpans = try await DiarizationService.shared.finishLive()?.spans
            } catch {
                DebugLog.shared.log("speakers", "live identification failed at stop, will run after stop instead: \(error)")
                await DiarizationService.shared.cancelLive()
            }
            identifiesSpeakersLive = false
        }
        var liveSegments = (try? await transcription?.finish()) ?? []
        transcription = nil
        if let nemotron {
            liveSegments = await nemotron.finish() ?? []
            self.nemotron = nil
        }

        #if os(iOS)
        sessionController.deactivate()
        #endif
        await liveActivity?.end()
        liveActivity = nil

        if liveIncomplete {
            liveSegments = []
            liveSpeakerSpans = nil
        }
        segments = liveSegments
        state = .idle

        // The length of what was saved: the timeline the transcript and playback use.
        // Clock time only if nothing was saved.
        let saved = chunks.reduce(0) { $0 + $1.duration }
        if abs(saved - accumulated) > 2 {
            DebugLog.shared.log("recording", "\(DebugLog.short(meetingID)): saved \(String(format: "%.1f", saved))s of audio over \(String(format: "%.1f", accumulated))s of recording time")
        }

        return RecordingResult(
            meetingID: meetingID,
            chunks: chunks,
            liveSegments: liveSegments,
            duration: saved > 0 ? saved : accumulated,
            locale: locale,
            liveSpeakerSpans: liveSpeakerSpans
        )
    }

    // MARK: - Capture

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecordingError.noInput }

        let continuation = bufferContinuation
        let drops = drops
        // Explicit, though AVAudioNode's imported signature already requires it.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            // Audio render thread. Copy the samples out, hand them off, return.
            // Nothing else: the engine reuses this buffer immediately.
            guard let captured = CapturedAudio(buffer) else { return }
            if case .dropped = continuation?.yield(captured) { drops.droppedSaved() }
        }
        engine.prepare()
        try engine.start()
    }

    private func startPump() {
        // ~45 s of audio at 48 kHz in 4,096-frame pieces. Saving keeps up easily;
        // this only covers a stall in the file system.
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        bufferContinuation = continuation
        // ~3 minutes (about 45 MB for mono input): room for a model to load or catch up.
        let (liveStream, liveContinuation) = AsyncStream<LiveAudio>.makeStream(
            bufferingPolicy: .bufferingNewest(2_048)
        )
        self.liveContinuation = liveContinuation

        let writer = writer
        let diarization = diarizationBuffer
        let transcription = transcription
        let nemotron = nemotron
        let live = identifiesSpeakersLive
        let drops = drops

        // Detached on purpose. A Task created here would inherit this type's
        // main-actor isolation, putting every audio buffer in the main actor's
        // region — and routing an hour of audio through the main actor to reach the
        // file writer would be wrong even if the compiler allowed it.
        //
        // Saving: never waits on a model.
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            for await captured in stream {
                // CapturedAudio is Sendable, so the same slice can go to every
                // consumer without any of them taking ownership of the others' copy.
                var samples: [Float] = []
                do {
                    try await writer?.write(captured)
                    samples = try await diarization?.append(captured) ?? []
                } catch {
                    await self?.recordFailure(error)
                }
                if case .dropped = liveContinuation.yield(LiveAudio(captured: captured, samples: samples)) {
                    drops.droppedLive()
                } else {
                    drops.enqueuedLive()
                }
                await self?.meter(peak: captured.peakLevel)
            }
            liveContinuation.finish()
        }

        // Live transcript and speakers: may fall behind without losing saved audio.
        livePump = Task.detached(priority: .userInitiated) { [weak self] in
            var liveRunning = live
            for await audio in liveStream {
                if drops.dequeuedLive() {
                    // Stopping with a long backlog: skip it (counted as dropped).
                    continue
                }
                if liveRunning {
                    do {
                        if let spans = try await DiarizationService.shared.appendLive(audio.samples) {
                            await self?.updateLiveSpans(spans)
                        }
                    } catch {
                        // The recording carries on; speakers are found after stop.
                        liveRunning = false
                        await DiarizationService.shared.cancelLive()
                        await self?.liveIdentificationFailed(error)
                    }
                }
                await transcription?.append(audio.captured)
                await nemotron?.append(audio.samples)
            }
        }
    }

    /// The last line is still being heard; show it as the volatile text.
    private func showNemotronLines(_ lines: [TranscriptSegment]) {
        guard state != .stopping, state != .idle else { return }
        segments = Array(lines.dropLast())
        volatileText = lines.last?.text ?? ""
    }

    private func updateLiveSpans(_ spans: [DiarizedSpan]) {
        liveSpans = spans
    }

    private func liveIdentificationFailed(_ error: Error) {
        identifiesSpeakersLive = false
        liveSpans = []
        DebugLog.shared.log("speakers", "live identification stopped, will run after stop instead: \(error)")
    }

    /// The meter and clock live on the main actor; the pump does not.
    private func meter(peak: Double) {
        // Smooth the meter so it reads as a level, not a strobe.
        level = level * 0.7 + peak * 0.3
        elapsed = currentElapsed
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

    private func recordFailure(_ error: Error) {
        log.error("Recording write failed: \(error.localizedDescription, privacy: .public)")
        failed(error.localizedDescription)
    }

    // MARK: - Interruptions

    #if os(iOS)
    private func handle(_ event: AudioSessionController.Event) {
        switch event {
        case .interruptionBegan:
            // Finalise what is in flight rather than dropping it (spec 4.1). Only
            // while recording: paused time was already counted.
            guard state == .recording else { return }
            Task {
                engine.pause()
                accumulated += Date().timeIntervalSince(startDate)
                try? await writer?.flush()
                try? await diarizationBuffer?.flush()
                state = .interrupted
                DebugLog.shared.log("recording", "interrupted by the system (a call, Siri or another app's audio)")
                await liveActivity?.update(elapsed: elapsed, level: 0, isPaused: true)
            }
        case .interruptionEnded(let shouldResume):
            // Only an interrupted recording: one the user paused stays paused.
            guard shouldResume, state == .interrupted else { return }
            Task { await resume() }
        case .routeChanged(let reason):
            // Nothing to do here: if the new route changes the input format, the
            // engine stops itself and `observeEngineConfiguration` restarts it.
            log.notice("Route changed: \(reason.rawValue, privacy: .public)")
            DebugLog.shared.log("recording", "audio route changed (reason \(reason.rawValue))")
        case .mediaServicesReset:
            recordFailure("Audio services restarted. The recording so far is saved.")
        }
    }

    private func recordFailure(_ message: String) {
        log.error("\(message, privacy: .public)")
        failed(message)
    }
    #endif

    /// A new input (headset, Bluetooth, a sample-rate change) stops the engine and
    /// posts this; without a restart, the rest of the meeting isn't recorded.
    private func observeEngineConfiguration() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    private func restartAfterConfigurationChange() {
        guard state == .recording else { return }
        DebugLog.shared.log("recording", "audio input changed; restarting capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try installTapAndStart() } catch { recordFailure(error) }
    }

    /// Stops the microphone and keeps what's saved. The recorder screen then offers
    /// Stop, which saves and processes the meeting as usual.
    private func failed(_ message: String) {
        if case .failed = state { return }
        guard state != .stopping, state != .idle else { return }
        if state == .recording {
            accumulated += Date().timeIntervalSince(startDate)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .failed(message)
        DebugLog.shared.log("recording", "stopped by an error; the audio so far is saved: \(message)")
        Task { await liveActivity?.update(elapsed: elapsed, level: 0, isPaused: true) }
    }
}

/// One captured piece and its 16 kHz copy, for the live consumers.
private struct LiveAudio: Sendable {
    var captured: CapturedAudio
    var samples: [Float]
}

/// Pieces of audio dropped because a loop fell behind. Written from the audio thread
/// and the saving loop, read at stop.
private final class DropCounter: Sendable {
    private let saved = Atomic<Int>(0)
    private let live = Atomic<Int>(0)
    private let queued = Atomic<Int>(0)
    private let skipping = Atomic<Bool>(false)

    func droppedSaved() { saved.add(1, ordering: .relaxed) }
    func droppedLive() { live.add(1, ordering: .relaxed) }
    func enqueuedLive() { queued.add(1, ordering: .relaxed) }
    var queuedLive: Int { queued.load(ordering: .relaxed) }
    func skipLiveBacklog() { skipping.store(true, ordering: .relaxed) }

    /// - Returns: true when this piece should be skipped (counted as dropped).
    func dequeuedLive() -> Bool {
        queued.subtract(1, ordering: .relaxed)
        guard skipping.load(ordering: .relaxed) else { return false }
        live.add(1, ordering: .relaxed)
        return true
    }

    func reset() {
        saved.store(0, ordering: .relaxed)
        live.store(0, ordering: .relaxed)
        queued.store(0, ordering: .relaxed)
        skipping.store(false, ordering: .relaxed)
    }

    var counts: (saved: Int, live: Int) {
        (saved.load(ordering: .relaxed), live.load(ordering: .relaxed))
    }
}

public struct RecordingResult: Sendable {
    public var meetingID: UUID
    public var chunks: [ChunkedAudioWriter.Chunk]
    public var liveSegments: [TranscriptSegment]
    public var duration: TimeInterval
    public var locale: Locale
    /// Speakers identified while recording, if that was on and worked. The pipeline
    /// uses these instead of running the batch pass.
    public var liveSpeakerSpans: [DiarizedSpan]? = nil
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
