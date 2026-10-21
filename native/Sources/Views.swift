import SwiftUI
import AppKit

@MainActor
struct QuotaPanelView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: ProviderIcon.codex(size: 17)).renderingMode(.template).foregroundStyle(Color.accentColor)
                Text("CodexUsageBar").font(.system(size: 13, weight: .semibold))
                Spacer()
                if state.isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.75) }
                Button { state.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(state.isRefreshing).help("向服务商核验额度").accessibilityLabel("刷新额度")
            }.padding(.horizontal, 20).padding(.vertical, 15)
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 19)).frame(width: 34, height: 34)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex").font(.system(size: 13, weight: .semibold))
                    Text(state.snapshot?.accountLabel ?? "本机 Codex 当前登录").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = state.snapshot?.planType {
                    Text(plan.capitalized).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.primary.opacity(0.04), in: Capsule())
                }
            }.padding(20)

            if let buckets = state.snapshot?.buckets, buckets.count > 1 {
                Picker("额度桶", selection: Binding(get: { state.bucket?.id ?? "codex" }, set: { state.preferences.selectedBucket = $0 })) {
                    ForEach(buckets) { bucket in Text(bucket.displayName).tag(bucket.id) }
                }.font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 12)
            }
            QuotaWindowView(window: state.bucket?.primary, fallback: "短周期额度", large: true, state: state)
            QuotaWindowView(window: state.bucket?.secondary, fallback: "长周期额度", large: false, state: state)

            TokenActivityView(state: state)

            if let message = state.errorMessage {
                statusNote(message, symbol: "exclamationmark.triangle", warning: true)
            } else if !state.verified {
                statusNote(state.isRefreshing ? "正在核验登录账号与套餐额度…" : "点击刷新，读取本机登录账号的额度。", symbol: "person.crop.circle.badge.checkmark", warning: false)
            } else if state.bucket?.spendControlReached == true || state.bucket?.rateLimitReachedType != nil {
                statusNote("服务商报告了使用限制，请同时查看 Codex 客户端提示。", symbol: "exclamationmark.triangle", warning: true)
            } else if state.isStale {
                statusNote("超过 5 分钟未核验，显示上次记录；菜单栏以 * 标记。", symbol: "clock", warning: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(state.timestampLabel + (state.verified ? " · 服务商返回" : " · 待核验"), systemImage: "checkmark.shield")
                Label(state.watchDescription, systemImage: state.preferences.refreshMode == .followClient ? "waveform.path" : "clock")
                if let date = state.lastClientChange {
                    Text("最近客户端变化 " + QuotaPresentation.time(date)).padding(.leading, 19)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(action: openSettings) { Label("显示与连接设置…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.plain).accessibilityLabel("打开 CodexUsageBar 设置")
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 13)
        }
        .overlay(alignment: .bottom) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 30, height: 3)
                .padding(.horizontal, 32).padding(.vertical, 4)
                .contentShape(Rectangle())
                .help("向下拖动以拉长弹窗")
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if state.panelDragStart == nil { state.panelDragStart = state.panelHeight }
                        state.onPanelResize?((state.panelDragStart ?? state.panelHeight) + value.translation.height)
                    }
                    .onEnded { _ in state.panelDragStart = nil })
        }
        .frame(width: 390, height: state.panelHeight)
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            Task { @MainActor in state.panelContentMeasured(height) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusNote(_ text: String, symbol: String, warning: Bool) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10)).lineSpacing(3)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .background((warning ? Color.orange : Color.accentColor).opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 20).padding(.bottom, 14)
    }
}

@MainActor
private struct QuotaWindowView: View {
    let window: QuotaWindow?
    let fallback: String
    let large: Bool
    @ObservedObject var state: AppState

    private var amount: String { QuotaPresentation.value(window, verified: state.verified, now: state.now) }
    private var remaining: Double? { amount == "--" ? nil : window?.remaining }
    private var color: Color {
        guard let remaining else { return .secondary }
        if remaining <= 5 { return Color(red: 0.93, green: 0.48, blue: 0.44) }
        if remaining <= 20 { return .orange }
        return large ? Color(red: 0.54, green: 0.65, blue: 0.97) : Color(red: 0.56, green: 0.64, blue: 0.78)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(window?.label ?? fallback).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(QuotaPresentation.resetLabel(window, now: state.now)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(amount.replacingOccurrences(of: "%", with: "")).font(.system(size: large ? 49 : 34, weight: .regular)).monospacedDigit().foregroundStyle(color)
                if amount != "--" { Text("%").font(.system(size: large ? 24 : 19)).foregroundStyle(.secondary) }
                Text(state.isStale && state.verified ? "上次剩余" : "剩余").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 5)
                Spacer()
            }
            HStack(spacing: 3) {
                ForEach(0..<36, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(remaining.map { Double(i) < $0 * 36 / 100 } == true ? color : Color.primary.opacity(0.06))
                        .frame(height: large ? 7 : 5)
                }
            }.accessibilityHidden(true)
            HStack {
                Text(remaining.map { "已用 " + QuotaPresentation.percent(100 - $0) } ?? (window?.isResetPending(at: state.now) == true ? "等待服务商确认重置" : "暂无有效数据"))
                Spacer()
                Text(window?.isResetPending(at: state.now) == true ? "不自动重置为 100%" : "独立额度窗口")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.bottom, large ? 24 : 20)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct UsageSettingsView: View {
    @ObservedObject var state: AppState

    private func bind<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { state.preferences[keyPath: key] }, set: { state.preferences[keyPath: key] = $0 })
    }
    var body: some View {
        TabView {
            Form {
                Section("菜单栏显示内容") {
                    Toggle("显示菜单栏图标", isOn: bind(\.showIcon))
                    if state.preferences.showIcon {
                        HStack(spacing: 7) {
                            Image(nsImage: ProviderIcon.codex()).resizable().frame(width: 18, height: 18)
                            Text("当前服务：Codex").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle((state.bucket?.primary?.label ?? "短周期") + "剩余", isOn: bind(\.showPrimary))
                    Toggle((state.bucket?.secondary?.label ?? "长周期") + "剩余", isOn: bind(\.showSecondary))
                    Toggle("短期重置（时:分）", isOn: bind(\.showPrimaryReset))
                    Toggle("长期重置（月-日）", isOn: bind(\.showSecondaryReset))
                    Toggle("套餐名称", isOn: bind(\.showPlan))
                }
                Section("排列方式") {
                    Toggle("菜单栏堆叠显示", isOn: bind(\.isStacked))
                    if state.preferences.isStacked {
                        Text("上方显示 7 天剩余，下方显示 5 小时剩余；具体窗口以账号返回为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("显示额度标签（例如 5h、7d）", isOn: bind(\.showLabels))
                    Toggle("显示重置描述（短期重置、长期重置）", isOn: bind(\.showResetDescriptions))
                    Toggle("使用分隔符", isOn: bind(\.useSeparator))
                    Picker("分隔符样式", selection: bind(\.separator)) {
                        Text("竖线  | ").tag("|"); Text("圆点  · ").tag("·"); Text("斜线  / ").tag("/"); Text("横线  — ").tag("—")
                    }.disabled(!state.preferences.useSeparator)
                    Text(state.preferences.useSeparator ? "用所选分隔符分开各项。" : "各项仅使用空格排开。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("实时预览") {
                    HStack(spacing: 6) {
                        if state.preferences.isStacked {
                            Image(nsImage: MenuBarRenderer.stackedImage(
                                lines: QuotaPresentation.stackedLines(snapshot: state.snapshot, preferences: state.preferences, verified: state.verified, now: state.now),
                                showIcon: state.preferences.showIcon))
                                .fixedSize()
                        } else {
                            if state.preferences.showIcon { Image(nsImage: ProviderIcon.codex()).resizable().frame(width: 17, height: 17) }
                            Text(state.menuTitle.isEmpty ? "仅显示图标" : state.menuTitle).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    Text("修改立即应用到真正的 macOS 菜单栏。* 表示旧快照，-- 表示未知或重置待确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("菜单栏", systemImage: "menubar.rectangle") }

            Form {
                Section("额度更新") {
                    Picker("更新方式", selection: bind(\.refreshMode)) {
                        ForEach(RefreshMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("默认跟随本机客户端额度变化：监听客户端写入和额度通知，再向服务商核验。不会把固定的 5 分钟轮询称为客户端频率。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("当前状态", value: state.watchDescription)
                    LabeledContent("最近更新", value: state.timestampLabel)
                    if let date = state.lastClientChange { LabeledContent("客户端变化", value: QuotaPresentation.time(date)) }
                    Button(state.isRefreshing ? "正在核验…" : "立即核验登录与额度") { state.refresh() }.disabled(state.isRefreshing)
                }
                Section("本机 Codex") {
                    LabeledContent("账号", value: state.snapshot?.accountLabel ?? "尚未核验")
                    LabeledContent("套餐", value: state.snapshot?.planType?.capitalized ?? "未知")
                    HStack {
                        TextField("Codex 路径（留空自动发现）", text: $state.cliDraft).font(.system(size: 11))
                        Button("选择…") { chooseCLI() }
                        Button("应用") { state.preferences.cliPath = state.cliDraft.trimmingCharacters(in: .whitespacesAndNewlines); state.refresh(reason: "应用连接设置") }
                    }
                    if let error = state.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button("复制 Codex 登录命令") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("codex login", forType: .string) }
                    Text("登录由 Codex 管理。应用不复制认证文件，不保存 token；CLI 和桌面客户端可能使用不同账号，请核对来源。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("数据口径") {
                    Text("直接展示服务商返回的已用比例，以 100 − 已用计算剩余；两个窗口不相加。日志只用于触发核验，不覆盖当前账号额度。重置时间到达后等待新响应，不凭空补成 100%。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("连接与更新", systemImage: "arrow.triangle.2.circlepath") }

            Form {
                LoginItemSettingsView(controller: state.loginItem)
                Section("外观") {
                    Picker("主题", selection: bind(\.appearance)) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("关于 CodexUsageBar") {
                    LabeledContent("版本", value: "0.1.1")
                    Text("只读套餐额度，常驻 macOS 菜单栏。时间按北京时间显示。")
                    Text("Token 活动来自官方账号统计；支持登录时自动启动，当前不包含系统通知。")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("外观与关于", systemImage: "circle.lefthalf.filled") }
        }
        .frame(width: 590, height: 650)
        .padding(.top, 10)
        .onAppear { state.cliDraft = state.preferences.cliPath }
    }

    private func chooseCLI() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.allowsMultipleSelection = false; picker.prompt = "选择 Codex"
        if picker.runModal() == .OK, let url = picker.url { state.cliDraft = url.path }
    }
}

private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor
private struct LoginItemSettingsView: View {
    @ObservedObject var controller: LoginItemController
    var body: some View {
        Section("启动") {
            Toggle("登录时自动启动", isOn: Binding(get: { controller.isOn }, set: { controller.setEnabled($0) }))
                .disabled(controller.isUpdating)
            Text(controller.statusText).font(.caption).foregroundStyle(.secondary)
            if controller.status == .requiresApproval {
                Button("打开系统登录项设置") { controller.openSystemSettings() }
            }
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("建议将应用移到“应用程序”文件夹后开启。移动应用后请重新确认登录项状态。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refresh() }
    }
}
