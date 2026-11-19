import SwiftUI
import AppKit

@MainActor
struct MenuColorRulesView: View {
    let title: String
    @Binding var rules: [PercentageColorRule]

    var body: some View {
        Section(title) {
            if rules.isEmpty {
                Text("默认配色与账号列表一致。剩余 20% 及以下为红色，超过 20% 至 50% 为琥珀色，超过 50% 为绿色。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($rules) { $rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("剩余")
                        TextField("起始", value: Binding(get: { rule.lower }, set: { rule.lower = min(100, max(0, $0)) }), format: .number)
                            .labelsHidden().frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.center).accessibilityLabel("区间起始百分比")
                        Text("% 至").foregroundStyle(.secondary)
                        TextField("结束", value: Binding(get: { rule.upper }, set: { rule.upper = min(100, max(0, $0)) }), format: .number)
                            .labelsHidden().frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.center).accessibilityLabel("区间结束百分比")
                        Text("%").foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        ColorPicker("数字颜色", selection: Binding(get: { Color(nsColor: MenuBarRenderer.color(rule.hex)) }, set: { value in
                            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                            rule.hex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                        }), supportsOpacity: false)
                            .labelsHidden().frame(width: 38).help("选择此区间的数字颜色")
                        Button(role: .destructive) { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("删除这条颜色规则").accessibilityLabel("删除颜色规则")
                    }.font(.system(size: 12))
                    if rule.lower > rule.upper {
                        Text("起始值不能大于结束值，此规则暂不生效。").font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.vertical, 5)
            }
            HStack {
                Button("添加区间") { rules.append(PercentageColorRule()) }.disabled(rules.count >= 12)
                Spacer()
                if !rules.isEmpty { Button("恢复默认") { rules = [] } }
            }
            Text("按真实剩余比例匹配，包含两端。重叠时优先使用上方规则，未命中时使用三档默认配色。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
