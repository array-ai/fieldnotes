import SwiftUI
import UIKit

/// Fieldnote's colours, taken from the app icon like the site's: the navy ground,
/// the paper page and the amber waveform. Each adapts to light and dark.
enum Theme {
    /// The waveform's amber: the tint for controls, links and timestamps.
    static let accent = dynamic(light: 0xC25A14, dark: 0xFFA057)
    /// Behind everything: paper in light, the icon's navy in dark.
    static let ground = dynamic(light: 0xF7F4EC, dark: 0x12141D)
    /// Cards and list rows, one step up from the ground.
    static let surface = dynamic(light: 0xFFFDF8, dark: 0x1A1E2B)
    /// A quiet amber wash: timestamp chips, the icon tile, the line being played.
    static let accentWash = accent.opacity(0.14)

    static let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    /// A list, form or scroll view on Fieldnote's ground instead of the system's.
    func themedGround() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
    }

    /// The rows of a section (or of several) on Fieldnote's surface colour.
    func themedRows() -> some View {
        listRowBackground(Theme.surface)
    }
}
