#if os(iOS)
import BackgroundTasks
import UIKit
import FieldnoteKit
import Foundation
import OSLog

/// Keeps the post-recording pipeline alive after the user pockets the phone.
///
/// `BGContinuedProcessingTask` starts from an explicit foreground action — pressing
/// stop — and continues once the app is backgrounded, with the system rendering
/// progress as a Live Activity the user can cancel (spec 4.7).
///
/// Two things this type exists to get right:
///
/// - **Registration happens at launch**, not at the call site. `BGTaskScheduler`
///   requires the handler to be registered before launch completes, and a
///   registration added later fails at submit time with an error that reads like a
///   provisioning problem.
/// - **Progress is reported per stage and often.** The system prioritises killing
///   tasks that report minimal progress. Three updates over an hour is a task that
///   gets killed at minute 40.
public final class BackgroundProcessingCoordinator: @unchecked Sendable {

    public static let taskIdentifier = "com.publicarray.fieldnotes.processing"

    private let log = Logger(subsystem: "com.publicarray.fieldnotes", category: "background")
    private let debug = DebugLog.shared
    private let provider: any ProcessingJobProvider
    private let pipelineFactory: @Sendable (Locale) -> ProcessingPipeline

    // A submit can land while a drain from an earlier submit is still running --
    // `resumeUnfinishedWork` at launch and `submitAfterRecording` on stop can fire close
    // together. Both would otherwise start their own `ProcessingPipeline` run over the
    // same pending jobs, racing to write the same meeting's checkpoint/segments files.
    // Only one drain runs at a time; a submit that arrives mid-drain just asks the
    // running one to loop again once it's done, rather than starting a second one.
    private let stateLock = NSLock()
    private var runningTask: Task<Void, Never>?
    private var redriveRequested = false
    /// The meeting the running drain is processing right now, so it can be stopped.
    private var currentMeetingID: UUID?

    public init(
        provider: any ProcessingJobProvider,
        pipelineFactory: @escaping @Sendable (Locale) -> ProcessingPipeline = { ProcessingPipeline(locale: $0) }
    ) {
        self.provider = provider
        self.pipelineFactory = pipelineFactory
    }

    // MARK: - Launch

    /// Call from `init` of the app type. Must complete before launch does.
    public func registerHandlers() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(task)
        }
    }

    /// Picks up anything left unfinished by a previous launch — a kill mid-pipeline,
    /// a device restart. Checkpoints mean this resumes rather than restarts.
    /// The user stopped a meeting's processing (the ✕ on its status). Its finished
    /// stages stay checkpointed; the store marks it stopped so nothing restarts it
    /// until the user asks. If it's the one running, the run is cancelled, and any
    /// other waiting meetings carry on once it has wound down.
    public func stop(meetingID: UUID) {
        stateLock.lock()
        let running = currentMeetingID == meetingID ? runningTask : nil
        stateLock.unlock()
        guard let running else { return }
        running.cancel()
        Task { [weak self] in
            await running.value
            self?.resumeUnfinishedWork()
        }
    }

    private func setCurrent(_ id: UUID?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        currentMeetingID = id
    }

    public func resumeUnfinishedWork() {
        Task { [weak self] in
            guard let self else { return }
            let pending = await provider.pendingJobs()
            guard !pending.isEmpty else { return }
            log.notice("Resuming \(pending.count, privacy: .public) unfinished meetings")
            await submit(
                title: pending.count == 1 ? "Processing meeting" : "Processing \(pending.count) meetings"
            )
        }
    }

    // MARK: - Submission

    /// Called when the user presses stop. That press is the foreground user action the
    /// task is anchored to.
    public func submitAfterRecording(title: String) async {
        await submit(title: "Processing \(title)")
    }

    /// Called from the debug "Redo" actions, which are also a foreground tap.
    public func submitRedo(title: String) async {
        await submit(title: title)
    }

    /// Async because iOS 27 deprecated the synchronous `submit`, in its own words,
    /// "to capture all error conditions" — and this call site depends on catching a
    /// failed submission to fall back to in-process work.
    private func submit(title: String) async {
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: title,
            subtitle: ProcessingStage.transcribing.displayName
        )
        // Defer under load rather than being refused outright.
        request.strategy = .queue

        // Only ask for the GPU if the system says it can give it. Developers have hit
        // cases where this returns false on capable hardware with a valid entitlement,
        // so a false answer is handled, not treated as broken provisioning.
        let gpu = BGTaskScheduler.supportedResources.contains(.gpu)
        if gpu {
            request.requiredResources = .gpu
        } else {
            log.notice("GPU resources unavailable for background tasks; running on CPU and Neural Engine")
        }

        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            log.notice("Submitted continued-processing task")
            debug.log("background", "submitted background task (GPU \(gpu ? "requested" : "unavailable")); waiting for the system to start it")
        } catch {
            log.error("Could not submit background task: \(error.localizedDescription, privacy: .public)")
            debug.log("background", "background task refused (\(error)); processing in the app instead")
            // The work still has to happen. Run it in-process; if the app is killed
            // before it finishes, the checkpoints mean the next launch resumes it.
            runInProcess()
        }
    }

    // MARK: - Execution

    private func handle(_ task: BGContinuedProcessingTask) {
        debug.log("background", "system started the background task")
        let reporter = ProgressReporter(progress: task.progress, task: task)

        stateLock.lock()
        guard runningTask == nil else {
            redriveRequested = true
            stateLock.unlock()
            log.notice("Continued-processing task submitted while a drain is already running; the running drain will pick up its work")
            task.setTaskCompleted(success: true)
            return
        }
        let work = Task { [weak self] in
            await self?.drainUntilIdle(reporting: reporter, inBackgroundTask: true)
            reporter.complete(success: true)
            // Summaries wait for an in-app run. If the app is open now, start it.
            await self?.continueInAppIfActive()
        }
        runningTask = work
        stateLock.unlock()

        task.expirationHandler = { [weak self] in
            // Expiry is normal on long runs. Stop promptly; the last completed stage is
            // already on disk, and the next launch resumes from it.
            self?.log.notice("Continued-processing task expired; checkpoint holds")
            self?.debug.log("background", "background task expired; stopping, the last finished stage is saved")
            work.cancel()
        }
    }

    private func runInProcess() {
        let reporter = ProgressReporter(
            progress: Progress(totalUnitCount: ProcessingStage.totalWeight),
            task: nil
        )

        stateLock.lock()
        guard runningTask == nil else {
            redriveRequested = true
            stateLock.unlock()
            log.notice("In-process drain requested while one is already running; the running drain will pick up its work")
            return
        }
        runningTask = Task { [weak self] in
            await self?.drainUntilIdle(reporting: reporter, inBackgroundTask: false)
        }
        stateLock.unlock()
    }

    /// Runs waiting work in the app itself — the only place summaries can run.
    /// Called when the app becomes active, and after a background task hands over.
    public func runPendingInApp() {
        Task { [weak self] in
            guard let self, !(await self.provider.pendingJobs().isEmpty) else { return }
            self.debug.log("background", "running waiting work in the app")
            self.runInProcess()
        }
    }

    private func continueInAppIfActive() async {
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        if active { runPendingInApp() }
    }

    /// Drains pending jobs, then drains again if a submit arrived while draining,
    /// repeating until nothing new showed up.
    private func drainUntilIdle(reporting reporter: ProgressReporter, inBackgroundTask: Bool) async {
        repeat {
            await drain(reporting: reporter, inBackgroundTask: inBackgroundTask)
        } while consumeRedriveRequest() && !Task.isCancelled
        clearRunningTask()
    }

    private func clearRunningTask() {
        stateLock.lock()
        defer { stateLock.unlock() }
        runningTask = nil
    }

    private func consumeRedriveRequest() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        defer { redriveRequested = false }
        return redriveRequested
    }

    private func drain(reporting reporter: ProgressReporter, inBackgroundTask: Bool) async {
        for job in await provider.pendingJobs() {
            if Task.isCancelled { return }
            // The list was fetched up front; skip a meeting the user stopped since.
            guard await provider.pendingJobs().contains(where: { $0.meetingID == job.meetingID }) else { continue }
            setCurrent(job.meetingID)
            defer { setCurrent(nil) }
            reporter.reset()
            let pipeline = pipelineFactory(job.locale)
            do {
                let output = try await pipeline.run(
                    job,
                    inBackgroundTask: inBackgroundTask,
                    progress: { stage, fraction in
                        // Reported on every fractional update, not once per stage: the
                        // system prioritises killing tasks that report little progress.
                        reporter.report(stage, fraction: fraction)
                    },
                    estimate: { [provider] stage, finish in
                        // Surface the stage and the estimate in the meeting list and
                        // the Live Activity, so both say the same thing.
                        reporter.setEstimate(finish, for: stage)
                        Task { await provider.markStage(stage, meetingID: job.meetingID, estimatedCompletion: finish) }
                    }
                )
                await provider.apply(output, to: job.meetingID)
                await ProcessingNotifier.shared.notifyFinished(
                    meetingID: job.meetingID,
                    title: job.title,
                    headline: output.summary.topics?.first?.title
                )
            } catch let deferred as SummarizationService.Deferred {
                // The model won't run for us right now (usually: app in the
                // background). Stop here; the rest would hit the same wall. The app
                // resumes everything next time it's open.
                await provider.markWaiting(meetingID: job.meetingID, message: deferred.localizedDescription)
                let active = await MainActor.run { UIApplication.shared.applicationState == .active }
                if !active {
                    await ProcessingNotifier.shared.notifyWaiting(meetingID: job.meetingID, title: job.title)
                }
                // A background-task handover: carry on with the other meetings'
                // transcripts and speakers. A real rate limit in the app: stop here.
                if deferred.withoutAttempt { continue }
                return
            } catch is CancellationError {
                log.notice("Processing cancelled for \(job.meetingID.uuidString, privacy: .public); checkpoint holds")
                debug.log("pipeline", "\(DebugLog.short(job.meetingID)): cancelled; will resume from the last finished stage")
                return
            } catch {
                log.error("Processing failed: \(error.localizedDescription, privacy: .public)")
                debug.log("pipeline", "\(DebugLog.short(job.meetingID)): failed: \(error)")
                await provider.markFailed(meetingID: job.meetingID, message: error.localizedDescription)
                await ProcessingNotifier.shared.notifyFailed(meetingID: job.meetingID, title: job.title)
            }
        }
    }
}

/// Bridges the pipeline's `@Sendable` progress callback to a `Progress` and a
/// `BGContinuedProcessingTask`, neither of which is `Sendable`.
///
/// Both are touched only from here, only ever to write a monotonic counter and a
/// subtitle string, and every access is behind the lock — so `@unchecked Sendable` is
/// a claim this type can actually honour rather than a way to silence the compiler.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: Progress
    private let task: BGContinuedProcessingTask?
    private let baseTitle: String
    private var currentStage: ProcessingStage?
    private var finishByStage: [ProcessingStage: Date] = [:]

    init(progress: Progress, task: BGContinuedProcessingTask?) {
        self.progress = progress
        self.task = task
        self.baseTitle = task?.title ?? "Processing"
        progress.totalUnitCount = ProcessingStage.totalWeight
    }

    /// - Returns: true the first time a given stage is seen, so callers can act on a
    ///   stage change without firing on every fractional update.
    @discardableResult
    func report(_ stage: ProcessingStage, fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        progress.completedUnitCount = stage.precedingWeight
            + Int64(Double(stage.progressWeight) * fraction)
        guard currentStage != stage else { return false }
        currentStage = stage
        task?.updateTitle(baseTitle, subtitle: subtitle(for: stage))
        return true
    }

    func setEstimate(_ finish: Date, for stage: ProcessingStage) {
        lock.lock()
        defer { lock.unlock() }
        finishByStage[stage] = finish
        if currentStage == stage {
            task?.updateTitle(baseTitle, subtitle: subtitle(for: stage))
        }
    }

    /// "Summarising · about 2 min left". Called with the lock held.
    private func subtitle(for stage: ProcessingStage) -> String {
        guard let finish = finishByStage[stage] else { return stage.displayName }
        return "\(stage.displayName) · \(max(0, finish.timeIntervalSinceNow).roughDuration) left"
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        progress.completedUnitCount = 0
        currentStage = nil
        finishByStage = [:]
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        task?.setTaskCompleted(success: success)
    }
}

#endif
