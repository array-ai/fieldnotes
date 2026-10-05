#if os(iOS)
import Foundation
import MetricKit
import UIKit

/// Puts the app's unexpected exits in the debug log: crashes, memory-limit kills and
/// watchdog kills, which otherwise leave no trace but a missing "done" line.
///
/// Three sources, all on the phone: a marker that says the app was open (so a launch
/// after it can tell the previous run ended while in front), memory warnings with the
/// memory left, and MetricKit's crash reports and exit counts, which iOS hands over
/// on a later launch. Only reasons and counts are logged, never call stacks.
final class CrashWatch: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = CrashWatch()
    private static let inFrontKey = "crashWatch.inFront"

    /// Call once per launch, after the launch line is logged.
    func start() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.inFrontKey) {
            DebugLog.shared.log("app", "the previous run ended while the app was open (a crash, or iOS closed it for memory)")
        }
        defaults.set(false, forKey: Self.inFrontKey)
        // Shows whether the increased memory limit took effect (about 3.1 GB without).
        DebugLog.shared.log("app", "\(Self.memoryLeft) memory available at launch, Core AI chip family \(OnDeviceModel.deviceArchitecture)")

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            UserDefaults.standard.set(true, forKey: Self.inFrontKey)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            UserDefaults.standard.set(false, forKey: Self.inFrontKey)
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            UserDefaults.standard.set(false, forKey: Self.inFrontKey)
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            DebugLog.shared.log("app", "memory warning, \(Self.memoryLeft) left")
        }
        if UIApplication.shared.applicationState == .active {
            defaults.set(true, forKey: Self.inFrontKey)
        }

        MXMetricManager.shared.add(self)
        log(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    /// Memory this process can still use before iOS closes it.
    static var memoryLeft: String {
        ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory)
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        log(payloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let front = exits.foregroundExitData
            let back = exits.backgroundExitData
            let summary = [
                ("memory limit in front", front.cumulativeMemoryResourceLimitExitCount),
                ("crashes in front", front.cumulativeBadAccessExitCount + front.cumulativeIllegalInstructionExitCount + front.cumulativeAbnormalExitCount),
                ("watchdog in front", front.cumulativeAppWatchdogExitCount),
                ("memory limit in background", back.cumulativeMemoryResourceLimitExitCount + back.cumulativeMemoryPressureExitCount),
                ("crashes in background", back.cumulativeBadAccessExitCount + back.cumulativeIllegalInstructionExitCount + back.cumulativeAbnormalExitCount),
                ("watchdog in background", back.cumulativeAppWatchdogExitCount),
                ("background task overran", back.cumulativeBackgroundTaskAssertionTimeoutExitCount),
                ("CPU limit in background", back.cumulativeCPUResourceLimitExitCount),
            ]
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0)" }
            guard !summary.isEmpty else { continue }
            DebugLog.shared.log("app", "exits reported by iOS for \(Self.day(payload.timeStampBegin)): \(summary.joined(separator: ", "))")
        }
    }

    private func log(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let parts = [
                    crash.exceptionType.map { "exception type \($0)" },
                    crash.exceptionCode.map { "code \($0)" },
                    crash.signal.map { "signal \($0)" },
                    crash.terminationReason.map { "reason \($0)" },
                ].compactMap { $0 }
                DebugLog.shared.log("app", "crash reported by iOS (build \(crash.metaData.applicationBuildVersion), \(Self.day(payload.timeStampEnd))): \(parts.joined(separator: ", "))")
            }
            for hang in payload.hangDiagnostics ?? [] {
                DebugLog.shared.log("app", "hang reported by iOS (build \(hang.metaData.applicationBuildVersion)): \(hang.hangDuration)")
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                DebugLog.shared.log("app", "CPU limit reported by iOS (build \(cpu.metaData.applicationBuildVersion)): \(cpu.totalCPUTime) over \(cpu.totalSampledTime)")
            }
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
#endif
