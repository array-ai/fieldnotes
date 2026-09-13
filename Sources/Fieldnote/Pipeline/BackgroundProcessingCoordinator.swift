#if os(iOS)
import BackgroundTasks
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
        if BGTaskScheduler.supportedResources.contains(.gpu) {
            request.requiredResources = .gpu
        } else {
            log.notice("GPU resources unavailable for background tasks; running on CPU and Neural Engine")
        }

        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            log.notice("Submitted continued-processing task")
        } catch {
            log.error("Could not submit background task: \(error.localizedDescription, privacy: .public)")
            // The work still has to happen. Run it in-process; if the app is killed
            // before it finishes, the checkpoints mean the next launch resumes it.
            runInProcess()
        }
    }

    // MARK: - Execution

    private func handle(_ task: BGContinuedProcessingTask) {
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
            await self?.drainUntilIdle(reporting: reporter)
            reporter.complete(success: true)
        }
        runningTask = work
        stateLock.unlock()

        task.expirationHandler = { [weak self] in
            // Expiry is normal on long runs. Stop promptly; the last completed stage is
            // already on disk, and the next launch resumes from it.
            self?.log.notice("Continued-processing task expired; checkpoint holds")
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
            await self?.drainUntilIdle(reporting: reporter)
        }
        stateLock.unlock()
    }

    /// Drains pending jobs, then drains again if a submit arrived while draining,
    /// repeating until nothing new showed up.
    private func drainUntilIdle(reporting reporter: ProgressReporter) async {
        repeat {
            await drain(reporting: reporter)
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

    private func drain(reporting reporter: ProgressReporter) async {
        for job in await provider.pendingJobs() {
            if Task.isCancelled { return }
            reporter.reset()
            let pipeline = pipelineFactory(job.locale)
            do {
                let output = try await pipeline.run(job) { [provider] stage, fraction in
                    // Reported on every fractional update, not once per stage: the
                    // system prioritises killing tasks that report little progress.
                    let stageChanged = reporter.report(stage, fraction: fraction)
                    guard stageChanged else { return }
                    // Surface the stage in the meeting list too, so a user looking at
                    // the app sees the same state as the Live Activity.
                    Task { await provider.markStage(stage, meetingID: job.meetingID) }
                }
                await provider.apply(output, to: job.meetingID)
            } catch is CancellationError {
                log.notice("Processing cancelled for \(job.meetingID.uuidString, privacy: .public); checkpoint holds")
                return
            } catch {
                log.error("Processing failed: \(error.localizedDescription, privacy: .public)")
                await provider.markFailed(meetingID: job.meetingID, message: error.localizedDescription)
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
        task?.updateTitle(baseTitle, subtitle: stage.displayName)
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        progress.completedUnitCount = 0
        currentStage = nil
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        task?.setTaskCompleted(success: success)
    }
}

#endif
