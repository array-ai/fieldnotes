#if os(iOS)
import UIKit

/// Keeps the phone from locking while any part of the app needs it awake: notes
/// being written in the app, a model preparing. One owner, so one part finishing
/// can't let the screen lock while another still needs it.
@MainActor
enum ScreenAwake {
    enum Reason: Hashable {
        case processing
        case preparingModel
        /// Debug mode's benchmark and notes comparison: minutes of model work that
        /// the phone locking would pause.
        case benchmark
    }

    private static var reasons: Set<Reason> = []

    static func set(_ reason: Reason, _ awake: Bool) {
        if awake { reasons.insert(reason) } else { reasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
#endif
