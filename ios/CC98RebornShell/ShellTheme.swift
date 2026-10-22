import SwiftUI
import UIKit

// Values follow MOBILE_UI_SPEC.md sections 4-6: readable light/dark pairs,
// 17pt body, 13pt captions and 44pt touch targets. Colors are semantic; do not
// add near-duplicate colors in individual views.
enum ShellTheme {
    static let pageBackground = color(light: 0xF6F7F8, dark: 0x16181B)
    static let surface = color(light: 0xFFFFFF, dark: 0x212428)
    static let secondarySurface = color(light: 0xF0F1F3, dark: 0x2B2E33)
    static let primaryText = color(light: 0x25282E, dark: 0xE9EBEF)
    static let secondaryText = color(light: 0x646A73, dark: 0xB6BCC6)
    static let separator = color(light: 0xDCE0E5, dark: 0x424750)
    static let accent = color(light: 0x1F7166, dark: 0x88C9BB)
    static let accentSoft = color(light: 0xE3F1ED, dark: 0x293E39)
    static let link = color(light: 0x326B9B, dark: 0x96BFE8)
    static let danger = color(light: 0xB5474A, dark: 0xF0A4A7)
    static let warning = color(light: 0x8B641D, dark: 0xE2C16E)
    static let positive = color(light: 0x167A3E, dark: 0x86EFAC)

    enum Fonts {
        static let navigationTitle = Font.headline
        static let pageTitle = Font.title2.weight(.semibold)
        static let body = Font.body
        static let topicTitle = Font.title2.weight(.semibold)
        static let metadata = Font.footnote
        static let footnote = Font.footnote
        static let caption = Font.caption
        static let mono = Font.system(.footnote, design: .monospaced)
    }

    enum Metrics {
        static let margin: CGFloat = 16
        static let compactMargin: CGFloat = 12
        static let touch: CGFloat = 44
        static let corner: CGFloat = 12
        static let compactCorner: CGFloat = 8
        static let groupSpacing: CGFloat = 24
        static let maximumReadingWidth: CGFloat = 680
    }

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

// The light mint accent in dark mode needs dark text, not a white label.
struct NativePrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(colorScheme == .dark ? Color(uiColor: UIColor(red: 0.09, green: 0.14, blue: 0.13, alpha: 1)) : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(ShellTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: ShellTheme.Metrics.compactCorner))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
