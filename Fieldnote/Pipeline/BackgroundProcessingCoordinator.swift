#if os(iOS)
import BackgroundTasks
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
    private var runningTask: Task<Void, Never>?

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
            submit(title: pending.count == 1 ? "Processing meeting" : "Processing \(pending.count) meetings")
        }
    }

    // MARK: - Submission

    /// Called when the user presses stop. That press is the foreground user action the
    /// task is anchored to.
    public func submitAfterRecording(title: String) {
        submit(title: "Processing \(title)")
    }

    private func submit(title: String) {
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
            try BGTaskScheduler.shared.submit(request)
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
        let work = Task { [weak self] in
            guard let self else { return }
            await self.drain(reporting: task.progress, subtitle: { [weak task] text in
                task?.updateTitle(task?.title ?? "Processing", subtitle: text)
            })
            task.setTaskCompleted(success: true)
        }
        runningTask = work

        task.expirationHandler = { [weak self] in
            // Expiry is normal on long runs. Stop promptly; the last completed stage is
            // already on disk, and the next launch resumes from it.
            self?.log.notice("Continued-processing task expired; checkpoint holds")
            work.cancel()
        }
    }

    private func runInProcess() {
        runningTask = Task { [weak self] in
            await self?.drain(reporting: Progress(totalUnitCount: ProcessingStage.totalWeight), subtitle: { _ in })
        }
    }

    private func drain(reporting progress: Progress, subtitle: @escaping @Sendable (String) -> Void) async {
        progress.totalUnitCount = ProcessingStage.totalWeight

        for job in await provider.pendingJobs() {
            if Task.isCancelled { return }
            progress.completedUnitCount = 0
            let pipeline = pipelineFactory(job.locale)
            let tracker = StageTracker()
            do {
                let output = try await pipeline.run(job) { [provider] stage, fraction in
                    progress.completedUnitCount = stage.precedingWeight
                        + Int64(Double(stage.progressWeight) * fraction)
                    subtitle(stage.displayName)
                    // Surface the stage change in the meeting list too, so a user
                    // looking at the app sees the same state as the Live Activity.
                    Task {
                        if await tracker.enter(stage) {
                            await provider.markStage(stage, meetingID: job.meetingID)
                        }
                    }
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
/// Fires once per stage, however often progress is reported.
private actor StageTracker {
    private var current: ProcessingStage?

    func enter(_ stage: ProcessingStage) -> Bool {
        guard current != stage else { return false }
        current = stage
        return true
    }
}
#endif
