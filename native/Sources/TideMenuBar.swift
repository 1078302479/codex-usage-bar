import AppKit

struct TideMenuPicture: Equatable {
    let style: TideMenuStyle
    let short: Double?
    let long: Double?
    let text: String
    let prefix: String
    let suffix: String
    let showIcon: Bool
    let low: Double
    let high: Double
    let stale: Bool
    var trailingIcon = false

    @MainActor static func make(account: AppState, preferences p: Preferences, style: TideMenuStyle? = nil) -> Self {
        let bucket = account.bucket
        func value(_ window: QuotaWindow?, shown: Bool) -> Double? {
            guard shown, account.verified, let window, !window.isResetPending(at: account.now) else { return nil }
            return window.remaining
        }
        let style = style ?? p.menuStyle
        let short = value(bucket?.primary, shown: p.showPrimary)
        let long = value(bucket?.secondary, shown: p.showSecondary)
        let minimum = [short, long].compactMap { $0 }.min()
        let text: String
        if style == .bars, let short, let long {
            text = QuotaPresentation.percent(short).replacingOccurrences(of: "%", with: "") + "/" + QuotaPresentation.percent(long).replacingOccurrences(of: "%", with: "")
        } else {
            text = p.showPrimary || p.showSecondary ? minimum.map(QuotaPresentation.percent) ?? "--" : ""
        }
        var prefix: [String] = [], suffix: [String] = []
        var afterQuota = false
        var trailingIcon = false
        for element in p.menuElements {
            if element == .shortQuota || element == .longQuota {
                if element.enabled(in: p) { afterQuota = true }
                continue
            }
            let label: String?
            switch element {
            case .reset:
                label = [(p.showPrimaryReset, bucket?.primary), (p.showSecondaryReset, bucket?.secondary)]
                    .compactMap { shown, window in
                        shown ? window?.resetDate.map { window?.isResetPending(at: account.now) == true ? "--" : QuotaPresentation.time($0) } : nil
                    }.joined(separator: " · ")
            case .plan: label = p.showPlan ? account.snapshot?.planType?.capitalized : nil
            case .icon: trailingIcon = afterQuota; label = nil
            case .forecast: label = p.tideShowForecast == true ? account.tideProjection?.exhaustion.map { QuotaPresentation.time($0) + " 用完" } : nil
            default: label = nil
            }
            if let label, !label.isEmpty {
                if afterQuota { suffix.append(label) } else { prefix.append(label) }
            }
        }
        let separator = p.useSeparator ? " " + p.separator + " " : " "
        let hasQuota = !text.isEmpty || p.showIcon
        let before = prefix.joined(separator: separator) + (!prefix.isEmpty && hasQuota && p.useSeparator ? separator : "")
        let after = (!suffix.isEmpty && hasQuota && p.useSeparator ? separator : "") + suffix.joined(separator: separator)
        return Self(style: style, short: short, long: long, text: !hasQuota && before.isEmpty && after.isEmpty ? "CodexUsageBar" : text,
                    prefix: before, suffix: after, showIcon: p.showIcon, low: p.tideLowThreshold ?? 20,
                    high: p.tideHighThreshold ?? 50, stale: account.isStale, trailingIcon: trailingIcon)
    }

    var imageDescription: String { [prefix, text, suffix].filter { !$0.isEmpty }.joined(separator: "，") }

    var shouldPulse: Bool { style == .mini && showIcon && !stale && ([short, long].compactMap { $0 }.min() ?? 100) < low }

    func image(dark: Bool? = nil, dimmedSignal: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let labelColor = dark.map { $0 ? NSColor.white : NSColor.black } ?? .labelColor
        func label(_ value: String) -> NSAttributedString { NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: labelColor]) }
        let before = label(prefix)
        let after = label(suffix)
        let amount = label(text + (stale && text != "--" ? "*" : ""))
        let symbolWidth: CGFloat = !showIcon ? 0 : style == .bars ? 32 : style == .mini ? 14 : 24
        let amountWidth = ceil(amount.size().width)
        let beforeWidth = prefix.isEmpty ? 0 : ceil(before.size().width) + 2
        let afterWidth = suffix.isEmpty ? 0 : ceil(after.size().width) + 2
        let width = amountWidth + symbolWidth + beforeWidth + afterWidth + 2
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let y = (22 - amount.size().height) / 2
            before.draw(at: NSPoint(x: 1, y: y))
            if showIcon {
                drawSymbol(at: beforeWidth + 1 + (trailingIcon ? amountWidth + 3 : 0), ink: labelColor, dimmedSignal: dimmedSignal)
            }
            amount.draw(at: NSPoint(x: beforeWidth + (trailingIcon ? 0 : symbolWidth) + 1, y: y))
            after.draw(at: NSPoint(x: width - afterWidth, y: y))
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = imageDescription
        return image
    }

    private func drawSymbol(at x: CGFloat, ink: NSColor, dimmedSignal: Bool) {
        let track = ink.withAlphaComponent(0.22)
        let coral = TidePalette.rgb(0xFF7A45), indigo = TidePalette.rgb(0x7B6CFF)
        switch style {
        case .bars:
            for (value, y, color) in [(long, CGFloat(12), indigo), (short, CGFloat(6), coral)] {
                let rect = NSRect(x: x, y: y, width: 26, height: 4)
                track.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                if let value, value > 0 {
                    color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: rect.width * value / 100, height: 4), xRadius: 2, yRadius: 2).fill()
                }
            }
        case .mini:
            if let remaining = [short, long].compactMap({ $0 }).min() {
                TidePalette.rgb(remaining >= high ? 0x22C493 : remaining >= low ? 0xFFB020 : 0xFF4D5E)
                    .withAlphaComponent(dimmedSignal ? 0.4 : 1).setFill()
            } else { track.setFill() }
            NSBezierPath(ovalIn: NSRect(x: x, y: 7, width: 8, height: 8)).fill()
        default:
            let center = NSPoint(x: x + 9, y: 11)
            for (value, radius, color) in [(short, CGFloat(7.7), coral), (long, CGFloat(3.8), indigo)] {
                if radius < 5 && value == nil { continue }
                let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                circle.lineWidth = 2.6; track.setStroke(); circle.stroke()
                if let value, value > 0 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 3.6 * value, clockwise: true)
                    arc.lineWidth = 2.6; arc.lineCapStyle = .round; color.setStroke(); arc.stroke()
                }
            }
        }
    }
}
