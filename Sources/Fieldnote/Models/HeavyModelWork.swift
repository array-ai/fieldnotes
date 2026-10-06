import Foundation

/// One heavy model job at a time: preparing a downloaded model, a processing run, the
/// benchmark. Each can take gigabytes; two together is how the app kept running out
/// of memory (Qwen preparing while the speaker model compiled, build 37; Parakeet v2
/// preparing during a benchmark, build 41: iOS reported 6 memory-limit exits in a
/// day). The others wait their turn.
actor HeavyModelWork {

    static let shared = HeavyModelWork()

    private var holder: String?
    private var waiting: [(label: String, continuation: CheckedContinuation<Void, Never>)] = []

    /// Waits until nothing else heavy is running, then holds the slot until
    /// `release`. Hand-over is direct, so nothing can slip in between.
    func acquire(_ label: String) async {
        guard let holder else {
            self.holder = label
            return
        }
        DebugLog.shared.log("memory", "\(label) waits for \(holder) to finish")
        await withCheckedContinuation { waiting.append((label, $0)) }
    }

    func release() {
        guard !waiting.isEmpty else {
            holder = nil
            return
        }
        let next = waiting.removeFirst()
        holder = next.label
        next.continuation.resume()
    }
}
