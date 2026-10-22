import AppKit
import SwiftUI

/// Panel-only colors; status-bar percentage colors remain user controlled.
enum PanelPalette {
    private static func adaptive(_ dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static var accountAccent: Color { adaptive(NSColor(srgbRed: 0.70, green: 0.73, blue: 0.90, alpha: 1), light: NSColor(srgbRed: 0.45, green: 0.43, blue: 0.76, alpha: 1)) }
    static var background: Color { adaptive(NSColor(srgbRed: 0.16, green: 0.175, blue: 0.195, alpha: 1), light: .windowBackgroundColor) }
    static var primary: Color { adaptive(NSColor(srgbRed: 0.88, green: 0.895, blue: 0.92, alpha: 1), light: .labelColor) }
    static var secondary: Color { adaptive(NSColor(srgbRed: 0.69, green: 0.72, blue: 0.77, alpha: 1), light: .secondaryLabelColor) }
    static var link: Color { adaptive(NSColor(srgbRed: 0.60, green: 0.71, blue: 0.88, alpha: 1), light: .controlAccentColor) }
    static var warning: Color { adaptive(NSColor(srgbRed: 0.87, green: 0.68, blue: 0.43, alpha: 1), light: .systemOrange) }
    static var ringTrack: Color { adaptive(NSColor(srgbRed: 0.23, green: 0.25, blue: 0.28, alpha: 1), light: .labelColor.withAlphaComponent(0.065)) }
    static var shortRing: Color { adaptive(NSColor(srgbRed: 0.62, green: 0.65, blue: 0.83, alpha: 1), light: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.96, alpha: 1)) }
    static var longRing: Color { adaptive(NSColor(srgbRed: 0.53, green: 0.66, blue: 0.73, alpha: 1), light: NSColor(srgbRed: 0.55, green: 0.70, blue: 0.81, alpha: 1)) }
}
