import SwiftUI
import AppKit

extension SettingsTab {
    var title: String {
        switch self {
        case .accounts: return "账号"
        case .menuBar: return "菜单栏"
        case .appearance: return "外观"
        case .connection: return "连接与更新"
        case .reminders: return "通知"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .accounts: return "person.2"
        case .menuBar: return "menubar.rectangle"
        case .appearance: return "circle.lefthalf.filled"
        case .connection: return "arrow.triangle.2.circlepath"
        case .reminders: return "bell"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .accounts: return "查看额度和切换登录是两件事，互不影响。"
        case .menuBar: return "修改即时生效，上方预览会跟着更新。"
        case .appearance: return "让界面与你的工作环境保持一致。"
        case .connection: return "管理客户端连接、额度核验与应用版本。"
        case .reminders: return "跟随客户端当前登录账号。"
        case .about: return "一个专注于 Codex 额度的菜单栏工具。"
        }
    }
}

@MainActor
struct UsageSettingsView: View {
    @ObservedObject var state: AppState
    var size = OrbitLayout.settingsSize
    @Environment(\.orbitPreview) private var preview
    private var compactWidth: Bool { size.width < 720 }
    private func bind<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { state.preferences[keyPath: key] }, set: { state.preferences[keyPath: key] = $0 })
    }
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([SettingsTab.accounts, .menuBar, .reminders, .appearance, .connection, .about], id: \.self) { tab in
                        Button { state.settingsTab = tab } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white).frame(width: 22, height: 22)
                                    .background(navColor(tab), in: RoundedRectangle(cornerRadius: 6))
                                Text(tab.title).font(.system(size: 13, weight: state.settingsTab == tab ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(state.settingsTab == tab ? TidePalette.card : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityAddTraits(state.settingsTab == tab ? .isSelected : [])
                    }
                    Spacer()
                    Text(state.appUpdates.currentVersion + " · Tide")
                        .font(.system(size: 11)).foregroundStyle(TidePalette.tertiary)
                        .padding(10)
                }
                .padding(.horizontal, 10).padding(.top, 37).padding(.bottom, 14)
                .frame(minHeight: size.height)
            }
            .frame(width: compactWidth ? 155 : 210).background(TidePalette.sidebar)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.settingsTab.title).font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        Text(state.settingsTab.subtitle).font(.system(size: 12.5)).foregroundStyle(TidePalette.tertiary)
                    }
                    Spacer()
                }.padding(.horizontal, compactWidth ? 18 : 30).padding(.top, 28).padding(.bottom, 12)
                settingsContent.id(state.settingsTab)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(TidePalette.card)
        }
        .foregroundStyle(TidePalette.ink).tint(TidePalette.indigo)
        .frame(width: size.width, height: size.height)
        .onAppear { state.cliDraft = state.preferences.cliPath }
        .alert("删除账号？", isPresented: Binding(get: { state.pendingAccountDeletion != nil }, set: { if !$0 { state.cancelAccountDeletion() } })) {
            Button("取消", role: .cancel) { state.cancelAccountDeletion() }
            Button("确认删除", role: .destructive) { state.confirmAccountDeletion() }
        } message: { Text("将退出并移除该账号，重新使用时需要登录。本地项目、聊天和模型配置会保留。") }
    }
    @ViewBuilder private var settingsContent: some View {
        switch state.settingsTab {
        case .accounts: accountsPage
        case .menuBar: menuPage
        case .appearance: appearancePage
        case .connection: connectionPage
        case .reminders:
            VStack(alignment: .leading, spacing: 0) {
                Text(state.reminderAccount.map { "当前登录账号：" + ($0.snapshot?.accountLabel ?? "等待核验") } ?? "等待确认当前登录账号")
                    .font(.caption).foregroundStyle(PanelPalette.secondary).padding(.horizontal, 30).padding(.top, 12)
                ResetCreditReminderSettingsView(controller: state.reminders, lowQuota: state.lowQuotaReminders).disabled(preview)
            }
        case .about: aboutPage
        }
    }
    private func navColor(_ tab: SettingsTab) -> Color {
        switch tab {
        case .accounts: TidePalette.indigo
        case .menuBar: TidePalette.coral
        case .reminders: TidePalette.red
        case .appearance: TidePalette.color(0x3A3D45)
        case .connection: TidePalette.green
        case .about: TidePalette.color(0x9A9CA3)
        }
    }

    private var accountsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let verifiedCounts = state.homeAccounts.compactMap { $0.state.verified ? $0.state.snapshot?.resetCredits?.availableCount : nil }
                Text("\(state.homeAccounts.count) 个账号" + (verifiedCounts.count == state.homeAccounts.count ? " · 共 \(verifiedCounts.reduce(0, +)) 张重置卡" : ""))
                    .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(TidePalette.tertiary)
                if DualClientPanelView.isVisible(state.dualClient) { DualClientPanelView(controller: state.dualClient) }
                if let message = state.accountManagementMessage {
                    Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(TidePalette.red)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: compactWidth ? 1 : 2),
                          alignment: .leading, spacing: 12) {
                    ForEach(state.orderedAccounts, id: \.id) { entry in
                        AccountSettingsCard(owner: state, account: entry.state, controller: state.dualClient, profileID: entry.id)
                    }
                    Button { state.addAccount() } label: {
                        VStack(spacing: 4) {
                            Text("＋ 添加账号").font(.system(size: 13, weight: .semibold))
                            Text("通过官方网页登录").font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity, minHeight: 130)
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(TidePalette.tertiary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(TidePalette.tertiary)
                }
            }.padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 24)
        }.disabled(preview)
    }

    private var menuPage: some View { TideMenuSettings(owner: state) }

    private var appearancePage: some View {
        Form {

                Section("主题") {
                    Picker("外观", selection: bind(\.appearance)) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("弹窗显示") {
                    Toggle("紧凑信息密度", isOn: Binding(get: { state.preferences.panelCompact == true }, set: { state.preferences.panelCompact = $0 }))
                    Toggle("固定为适屏高度", isOn: Binding(get: { state.preferences.panelFitsScreen == true }, set: { state.preferences.panelFitsScreen = $0 }))
                    Text("默认随内容展开，超出屏幕后内部滚动；也可以拖动弹窗底部调整高度。切换高度策略会清除本次拖动偏好。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LoginItemSettingsView(controller: state.loginItem).disabled(preview)

        }.formStyle(.grouped)
    }
    private var connectionPage: some View {
        Form {

                Section("本机 Codex") {
                    LabeledContent("账号", value: state.snapshot?.accountLabel ?? "尚未核验")
                    LabeledContent("套餐", value: state.snapshot?.planType?.capitalized ?? "未知")
                    HStack {
                        TextField("Codex 路径（留空自动发现）", text: $state.cliDraft).font(.system(size: 11))
                        Button("选择…") { chooseCLI() }.disabled(preview)
                        Button("应用") { state.preferences.cliPath = state.cliDraft.trimmingCharacters(in: .whitespacesAndNewlines); state.refresh(reason: "应用连接设置") }.disabled(preview)
                    }
                    Text("可选择 Codex / ChatGPT 应用或 codex 可执行文件；留空自动发现。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = state.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button("复制 Codex 登录命令") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("codex login", forType: .string) }
                    Text("登录由 Codex 管理。应用不复制认证文件，不保存 token；CLI 和桌面客户端可能使用不同账号，请核对来源。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("额度更新") {
                    Picker("更新方式", selection: bind(\.refreshMode)) {
                        ForEach(RefreshMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("默认跟随本机客户端额度变化，并在面板显示时每 15 秒、后台每 60 秒补充核验额度，避免漏掉重置卡或其他设备的变化。补查不拉取 Token 统计，休眠时暂停，失败后按退避策略重试。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("当前状态", value: state.updateStatus.title)
                    Text(state.statusDetail).font(.caption)
                        .foregroundStyle(state.updateStatus.isWarning ? Color.orange : Color.secondary)
                    LabeledContent("更新方式", value: state.watchDescription)
                    LabeledContent("最近更新", value: state.timestampLabel)
                    if let date = state.lastClientChange { LabeledContent("客户端变化", value: QuotaPresentation.time(date)) }
                    Button(state.isRefreshing ? "正在核验…" : "立即核验登录与额度") { state.refresh() }.disabled(state.isRefreshing || preview)
                }
                AppUpdateSettings(updates: state.appUpdates).disabled(preview)
                Section("数据口径") {
                    Text("直接展示服务商返回的已用比例，以 100 − 已用计算剩余；两个窗口不相加。日志只用于触发核验，不覆盖当前账号额度。重置时间到达后等待新响应，不凭空补成 100%。")
                        .font(.caption).foregroundStyle(.secondary)
                }

        }.formStyle(.grouped)
    }
    private var aboutPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                OrbitMark(size: 50)
                    .padding(.top, 24)
                Text("CodexUsageBar").font(.system(size: 24, weight: .semibold)).tracking(-0.6)
                Text("让额度、重置时间与工作节奏，一目了然。").font(.system(size: 12)).foregroundStyle(PanelPalette.secondary)
                Text("v" + state.appUpdates.currentVersion).font(.caption).foregroundStyle(PanelPalette.secondary)
                VStack(spacing: 0) {
                    Link(destination: URL(string: "https://github.com/1078302479/codex-usage-bar")!) {
                        HStack { Text("GitHub 项目"); Spacer(); Image(systemName: "arrow.up.right") }.padding(15)
                    }
                    Divider()
                    Button { state.settingsTab = .connection } label: {
                        HStack { Text("版本与更新"); Spacer(); Image(systemName: "chevron.right") }.padding(15)
                    }.buttonStyle(.plain)
                }.font(.system(size: 12)).overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(PanelPalette.border) }.padding(.top, 16)
                Text("独立社区项目，与 OpenAI 没有隶属关系。额度和 Token 数据来自本机 Codex 客户端，时间按北京时间显示。")
                    .font(.system(size: 11)).foregroundStyle(PanelPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.bottom, 28)
        }
    }
    private func chooseCLI() {
        guard !preview else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.allowsMultipleSelection = false; picker.prompt = "选择 Codex"
        picker.message = "选择 Codex / ChatGPT 应用或 codex 可执行文件，应用会自动定位内置 CLI。"
        if picker.runModal() == .OK, let url = picker.url { state.cliDraft = url.path }
    }
}
