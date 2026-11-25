import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TideMenuSettings: View {
    @ObservedObject var owner: AppState
    @StateObject private var interaction = Interaction()

    private final class Interaction: ObservableObject {
        var dragged: TideMenuElement?
        var thresholdStart: Double?
    }

    private var preferences: Preferences { owner.preferences }
    private let styles: [TideMenuStyle] = [.ring, .stack, .bars, .mini]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                heading("实时预览")
                VStack(spacing: 8) {
                    previewBar(dark: false)
                    previewBar(dark: true)
                }.padding(18)
                    .background(LinearGradient(colors: [TidePalette.color(0xFFD9C7), TidePalette.color(0xD9D2FF), TidePalette.color(0xBFE6FF)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 14))
                heading("样式").padding(.top, 10)
                HStack(spacing: 10) {
                    ForEach(styles) { style in
                        let selected = preferences.menuStyle == style
                        Button {
                            var next = preferences
                            next.isStacked = style == .stack
                            next.tideMenuStyle = style
                            owner.preferences = next
                        } label: {
                            VStack(spacing: 7) {
                                glyph(style, dark: false, sample: true).frame(height: 34)
                                Text(style.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? TidePalette.indigo : TidePalette.line, lineWidth: 1.5) }
                                .background {
                                    if selected { RoundedRectangle(cornerRadius: 14).stroke(TidePalette.indigo.opacity(0.18), lineWidth: 5) }
                                }
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                heading("显示元素 · 拖动排序，点击开关").padding(.top, 10)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ForEach(preferences.menuElements) { element in token(element) }
                    }.fixedSize(horizontal: true, vertical: false)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 5)], alignment: .leading, spacing: 5) {
                        ForEach(preferences.menuElements) { element in token(element) }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TidePalette.settingsSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(TidePalette.tertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                heading("颜色阈值").padding(.top, 10)
                thresholds
                DisclosureGroup("高级显示设置") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("单行文字", isOn: Binding(get: { preferences.menuStyle == .legacy },
                                                      set: { owner.preferences.isStacked = false; owner.preferences.tideMenuStyle = $0 ? .legacy : .ring }))
                        Toggle("显示额度标签", isOn: bind(\.showLabels))
                        Toggle("短期重置（时:分）", isOn: bind(\.showPrimaryReset))
                        Toggle("长期重置（月-日）", isOn: bind(\.showSecondaryReset))
                        Toggle("显示重置描述", isOn: bind(\.showResetDescriptions))
                        Toggle("账号列表跟随自定义颜色", isOn: bind(\.followsQuotaColors))
                        Picker("分隔符", selection: bind(\.separator)) {
                            ForEach(["|", "·", "/", "—"], id: \.self) { Text($0).tag($0) }
                        }.disabled(!preferences.useSeparator)
                        Form {
                            MenuColorRulesView(title: "5 小时百分比颜色", rules: Binding(
                                get: { preferences.primaryColorRules ?? [] }, set: { owner.preferences.primaryColorRules = $0 }))
                            MenuColorRulesView(title: "7 天百分比颜色", rules: Binding(
                                get: { preferences.secondaryColorRules ?? [] }, set: { owner.preferences.secondaryColorRules = $0 }))
                        }.formStyle(.grouped).frame(height: 340)
                    }.padding(.top, 8)
                }.font(.system(size: 11)).padding(.top, 5)
            }.padding(.horizontal, 30).padding(.vertical, 10).padding(.bottom, 18)
        }
    }

    private func bind<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { preferences[keyPath: key] }, set: { owner.preferences[keyPath: key] = $0 })
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(TidePalette.tertiary)
    }

    private func previewBar(dark: Bool) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Image(systemName: "circle.lefthalf.filled")
            Image(systemName: "battery.75percent")
            glyph(preferences.menuStyle, dark: dark, sample: false).padding(.horizontal, 6)
                .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            Text(QuotaPresentation.time(owner.now)).monospacedDigit()
        }.font(.system(size: 12)).foregroundStyle(dark ? Color.white : .black)
            .padding(.horizontal, 12).frame(height: 30)
            .background((dark ? Color.black.opacity(0.65) : Color.white.opacity(0.55)), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(dark ? "深色菜单栏预览" : "浅色菜单栏预览")
    }

    @ViewBuilder private func glyph(_ style: TideMenuStyle, dark: Bool, sample: Bool) -> some View {
        let account = owner.menuBarAccount
        if style == .stack {
            if sample {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.system(size: 12, weight: .semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("7d 33% · 11-12")
                        Text("5h 49% · 13:53")
                    }.font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                }.foregroundStyle(.black)
            } else {
                Image(nsImage: MenuBarRenderer.stackedImage(
                    lines: QuotaPresentation.stackedLines(snapshot: account.snapshot, preferences: preferences, verified: account.verified, now: account.now),
                    showIcon: preferences.showIcon,
                    colors: MenuBarRenderer.stackedColors(snapshot: account.snapshot, preferences: preferences, verified: account.verified, now: account.now),
                    foreground: dark ? .white : .black))
            }
        } else if style == .legacy {
            HStack(spacing: 5) {
                if preferences.showIcon {
                    Image(nsImage: TideAppIcon.menuGlyph).renderingMode(.template)
                }
                Text(account.menuTitle).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        } else {
            let picture = sample
                ? TideMenuPicture(style: style, short: 49, long: 33, text: style == .bars ? "49/33" : "33%", prefix: "", suffix: "", showIcon: true,
                                  low: 20, high: 50, stale: false)
                : TideMenuPicture.make(account: account, preferences: preferences, style: style)
            Image(nsImage: picture.image(dark: dark)).fixedSize()
        }
    }

    private func token(_ element: TideMenuElement) -> some View {
        let enabled = element.enabled(in: preferences)
        return Button {
            var next = owner.preferences
            element.toggle(in: &next)
            owner.preferences = next
        } label: {
            HStack(spacing: 4) {
                Text(enabled ? "⋮⋮" : "＋").foregroundStyle(TidePalette.tertiary)
                if enabled && (element == .shortQuota || element == .longQuota) {
                    RoundedRectangle(cornerRadius: 2).fill(element == .shortQuota ? TidePalette.coral : TidePalette.indigo)
                        .frame(width: 7, height: 7)
                }
                Text(element.title).lineLimit(1).minimumScaleFactor(0.72)
            }.font(.system(size: 11, weight: enabled ? .semibold : .medium))
                .padding(.horizontal, 6).padding(.vertical, 6)
                .background(enabled ? TidePalette.card : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay { if !enabled { RoundedRectangle(cornerRadius: 9).strokeBorder(TidePalette.line) } }
                .foregroundStyle(enabled ? TidePalette.ink : TidePalette.tertiary)
        }.buttonStyle(.plain)
            .onDrag { interaction.dragged = element; return NSItemProvider(object: element.rawValue as NSString) }
            .onDrop(of: [.text], isTargeted: nil) { _ in
                guard let moved = interaction.dragged, moved != element else { return false }
                var order = preferences.menuElements
                guard let from = order.firstIndex(of: moved), let to = order.firstIndex(of: element) else { return false }
                order.remove(at: from)
                order.insert(moved, at: to)
                owner.preferences.tideMenuOrder = order
                interaction.dragged = nil
                return true
            }
    }

    private var thresholds: some View {
        let low = preferences.tideLowThreshold ?? 20
        let high = preferences.tideHighThreshold ?? 50
        return VStack(spacing: 7) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    LinearGradient(stops: [.init(color: TidePalette.red, location: 0),
                                           .init(color: TidePalette.red, location: low / 100),
                                           .init(color: TidePalette.amber, location: low / 100),
                                           .init(color: TidePalette.amber, location: high / 100),
                                           .init(color: TidePalette.green, location: high / 100),
                                           .init(color: TidePalette.green, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule()).frame(height: 10)
                    handle(width: width, value: low, label: "紧张阈值") { owner.preferences.tideLowThreshold = min(high - 1, max(1, $0)) }
                    handle(width: width, value: high, label: "注意阈值") { owner.preferences.tideHighThreshold = min(99, max(low + 1, $0)) }
                }
            }.frame(height: 22)
            HStack { Text("0%"); Spacer(); Text("\(Int(low))%"); Spacer(); Text("\(Int(high))%"); Spacer(); Text("100%") }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(TidePalette.tertiary)
        }
    }

    private func handle(width: CGFloat, value: Double, label: String, change: @escaping (Double) -> Void) -> some View {
        Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: 20, height: 20).offset(x: width * value / 100 - 10)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { drag in
                guard width > 0 else { return }
                let position = drag.location.x - drag.startLocation.x
                let percentDelta = Double(position / width) * 100
                if interaction.thresholdStart == nil { interaction.thresholdStart = value }
                change(((interaction.thresholdStart ?? value) + percentDelta).rounded())
            }.onEnded { _ in interaction.thresholdStart = nil })
            .accessibilityLabel(label).accessibilityValue("\(Int(value))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: change(value + 1)
                case .decrement: change(value - 1)
                @unknown default: break
                }
            }
    }

}
