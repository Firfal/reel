import CoreText
import SwiftUI

/// Every brand decision lives here. Art direction: « Halo » (warm, Arc/Dia-like), with the editor timeline
/// borrowed from « Sable » (a strip of video frames rather than a waveform).
enum Theme {
    /// The single accent, apricot, used only for actions and playback.
    static let accent = Color(light: 0xE2703A, dark: 0xF08B52)
    /// Accent for text and icons on light surfaces, where the plain accent lacks contrast.
    static let accentInk = Color(light: 0xB2521D, dark: 0xF6A576)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x1F140D)
    /// Soft accent fill behind selected rows and the playhead halo.
    static let accentSoft = Color(light: 0xE2703A, dark: 0xF08B52).opacity(0.14)

    /// Warm neutrals.
    static let canvas = Color(light: 0xFAF7F4, dark: 0x1C1815)
    static let inset = Color(light: 0xF3EEE9, dark: 0x191512)
    static let line = Color(light: 0x462D19, dark: 0xFFEBDC).opacity(0.10)

    /// The brand gradient. It lives only in the sidebar and panel backgrounds, never on content.
    static let sidebarTint = LinearGradient(
        colors: [Color(light: 0xFDE2CE, dark: 0x784022).opacity(0.55), .clear],
        startPoint: .top,
        endPoint: .center
    )

    /// Display face for titles; the UI itself stays on the system font.
    static func title(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Instrument Sans", size: size).weight(weight)
    }

    enum Radius {
        static let panel: CGFloat = 18
        static let control: CGFloat = 10
        static let card: CGFloat = 12
        static let bubbleSquircle: CGFloat = 0.225  // fraction of the bubble's side, the proportion of an app icon
    }

    /// Floating panels share one inset from the screen edges (and from the Dock), so they line up with each other.
    enum Layout {
        static let screenMargin: CGFloat = 20
        /// Between two floating panels, such as the bubble and the teleprompter.
        static let panelGap: CGFloat = 12
    }

    enum Motion {
        /// Critically damped default: no overshoot.
        static let standard = Animation.spring(response: 0.35, dampingFraction: 1)
        /// Only after a gesture that carried momentum (throwing the camera bubble).
        static let thrown = Animation.spring(response: 0.4, dampingFraction: 0.8)
    }

    /// Registers the bundled title font. Call once at launch.
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "InstrumentSans", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Color {
    /// A color with distinct light and dark appearances, from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
