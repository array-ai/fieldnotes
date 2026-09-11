import SwiftUI

/// The refusal screen. Plain explanation, no workaround offered, because there is
/// not one: Fieldnote needs the Apple Intelligence stack (spec 10).
struct UnsupportedDeviceView: View {
    let status: DeviceCapability.Status
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(status.headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(status.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if status != .unsupportedHardware {
                Button("Check again", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }

    private var symbol: String {
        switch status {
        case .unsupportedHardware: "iphone.slash"
        case .modelNotReady: "arrow.down.circle"
        default: "exclamationmark.triangle"
        }
    }
}
