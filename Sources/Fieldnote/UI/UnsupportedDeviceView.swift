import SwiftUI

/// The refusal screen. Plain explanation, no workaround offered, because there is
/// not one: Fieldnote needs the Apple Intelligence stack (spec 10).
struct UnsupportedDeviceView: View {
    let status: DeviceCapability.Status
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 96, height: 96)
                .background(Theme.accentWash, in: Circle())
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
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
    }

    private var symbol: String {
        switch status {
        case .unsupportedHardware: "iphone.slash"
        case .modelNotReady: "arrow.down.circle"
        default: "exclamationmark.triangle"
        }
    }
}
