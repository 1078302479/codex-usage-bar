import AppKit
import SwiftUI

enum TidePalette {
    static let coral = color(0xFF7A45)
    static let indigo = color(0x7B6CFF)
    static let green = color(0x22C493)
    static let amber = color(0xFFB020)
    static let red = color(0xFF4D5E)
    // The prototype composites its translucent dark shell over the preview canvas.
    // Use the resulting color so the macOS material behind the panel cannot shift it.
    static var background: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? rgb(0x232327)
                : rgb(0xFAF9F6).withAlphaComponent(0.94)
        })
    }
    static var card: Color { adaptive(0xFFFFFF, 0x1F2128) }
    static var surface: Color { adaptive(0xF3F2EE, 0x272A32) }
    static var tank: Color { adaptive(0xEFEDE8, 0x2A2D35) }
    static var ink: Color { adaptive(0x17191E, 0xF3F3F5) }
    static var secondary: Color { adaptive(0x5E616A, 0xA6A9B2) }
    static var tertiary: Color { adaptive(0x9A9CA3, 0x6C6F78) }
    static var line: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? rgb(0xFFFFFF).withAlphaComponent(0.07)
                : rgb(0x14161E).withAlphaComponent(0.08)
        })
    }
    static var sidebar: Color { adaptive(0xF1EFEB, 0x1B1D23) }
    static var settingsSurface: Color { adaptive(0xF6F5F2, 0x272A32) }

    static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255, alpha: 1)
    }

    static func color(_ value: UInt32) -> Color { Color(nsColor: rgb(value)) }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    static func statusRGB(_ remaining: Double, preferences: Preferences) -> NSColor {
        rgb(remaining >= (preferences.tideHighThreshold ?? 50) ? 0x22C493 :
                remaining >= (preferences.tideLowThreshold ?? 20) ? 0xFFB020 : 0xFF4D5E)
    }
}

enum TideQuotaKind {
    case short, long

    var marker: Color { self == .short ? TidePalette.coral : TidePalette.indigo }

    func liquidColors(dark: Bool) -> (surface: Color, bottom: Color) {
        let stops: (UInt32, UInt32)
        switch (self, dark) {
        case (.short, false): stops = (0xFF9035, 0xFDAC6D)
        case (.long, false): stops = (0xB286A0, 0xC5A7B6)
        case (.short, true): stops = (0xFF6153, 0xBB4D45)
        case (.long, true): stops = (0xC49184, 0x916E67)
        }
        return (TidePalette.color(stops.0), TidePalette.color(stops.1))
    }
}

enum TideTypography {
    static let body = Font.system(size: 13, weight: .medium)
    static let account = Font.system(size: 13, weight: .semibold)
    static let section = Font.system(size: 12, weight: .bold)
    static let subheading = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .regular)
    static let metadata = Font.system(size: 11, weight: .medium)
    static let metric = Font.system(size: 18, weight: .heavy)
    static let mono = Font.system(size: 10, weight: .regular, design: .monospaced)
}

struct TideAvatar: View {
    let index: Int
    var size: CGFloat = 30

    static func label(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(65 + index)!) : String(index + 1)
    }

    var body: some View {
        let colors: [(UInt32, UInt32)] = [(0xFF8A50, 0xFF4D7A), (0x7B6CFF, 0x4DB6FF), (0x22C493, 0x14A0A0)]
        let pair = colors[index % colors.count]
        Text(Self.label(index))
            .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [TidePalette.color(pair.0), TidePalette.color(pair.1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size / 3, style: .circular))
            .accessibilityHidden(true)
    }
}

struct TideRings: View {
    let short: Double?
    let long: Double?
    var size: CGFloat = 36
    var stroke: CGFloat = 4

    var body: some View {
        ZStack {
            ring(short, color: TidePalette.coral, diameter: size)
            if long != nil {
                ring(long, color: TidePalette.indigo, diameter: size - 2 * stroke - 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ring(_ value: Double?, color: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle().strokeBorder(TidePalette.ink.opacity(0.14), lineWidth: stroke)
            if let value, value > 0 {
                Circle().inset(by: stroke / 2).trim(from: 0, to: value / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }.frame(width: diameter, height: diameter)
    }
}

extension AppState {
    func tideAvatarLabel(_ id: String) -> String { TideAvatar.label(tideAvatarIndex(id)) }
}
