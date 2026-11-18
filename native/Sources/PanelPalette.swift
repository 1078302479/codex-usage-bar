import AppKit
import SwiftUI

/// Panel-only colors; status-bar percentage colors remain user controlled.
enum PanelPalette {
    private static func adaptive(_ dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static var accountAccent: Color { longRing }
    static var background: Color { adaptive(NSColor(srgbRed: 0.165, green: 0.169, blue: 0.192, alpha: 1), light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) }
    static var primary: Color { adaptive(NSColor(srgbRed: 0.933, green: 0.929, blue: 0.949, alpha: 1), light: NSColor(srgbRed: 0.161, green: 0.169, blue: 0.188, alpha: 1)) }
    static var secondary: Color { adaptive(NSColor(srgbRed: 0.65, green: 0.64, blue: 0.70, alpha: 1), light: NSColor(srgbRed: 0.49, green: 0.49, blue: 0.54, alpha: 1)) }
    static var link: Color { primary }
    static var warning: Color { adaptive(NSColor(srgbRed: 0.89, green: 0.72, blue: 0.47, alpha: 1), light: NSColor(srgbRed: 0.65, green: 0.43, blue: 0.16, alpha: 1)) }
    static var ringTrack: Color { adaptive(NSColor(srgbRed: 0.23, green: 0.23, blue: 0.26, alpha: 1), light: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)) }
    static var shortRing: Color { adaptive(NSColor(srgbRed: 0.90, green: 0.64, blue: 0.45, alpha: 1), light: NSColor(srgbRed: 0.875, green: 0.55, blue: 0.33, alpha: 1)) }
    static var longRing: Color { adaptive(NSColor(srgbRed: 0.71, green: 0.64, blue: 0.89, alpha: 1), light: NSColor(srgbRed: 0.60, green: 0.54, blue: 0.79, alpha: 1)) }
    static var surface: Color { adaptive(NSColor(srgbRed: 0.19, green: 0.195, blue: 0.22, alpha: 1), light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1)) }
    static var border: Color { ringTrack }
    static func remainingQuotaText(_ remaining: Double) -> Color {
        if remaining <= 20 {
            return adaptive(NSColor(srgbRed: 1, green: 0.56, blue: 0.60, alpha: 1),
                            light: NSColor(srgbRed: 0.74, green: 0.15, blue: 0.23, alpha: 1))
        }
        if remaining <= 50 { return warning }
        return adaptive(NSColor(srgbRed: 0.45, green: 0.85, blue: 0.63, alpha: 1),
                        light: NSColor(srgbRed: 0.06, green: 0.44, blue: 0.29, alpha: 1))
    }
}
