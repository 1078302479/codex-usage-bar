import SwiftUI
import AppKit

extension SettingsTab {
    var title: String {
        switch self {
        case .accounts: return "账号管理"
        case .menuBar: return "菜单栏显示"
        case .appearance: return "外观与通用"
        case .connection: return "连接与更新"
        case .reminders: return "通知提醒"
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
        case .accounts: return "额度查看与客户端换号，各自独立。"
        case .menuBar: return "在菜单栏留下你最需要的信息。"
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
    @Environment(\.orbitPreview) private var preview
    private func bind<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { state.preferences[keyPath: key] }, set: { state.preferences[keyPath: key] = $0 })
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) { OrbitMark(); VStack(alignment: .leading, spacing: 2) {
                    Text("CodexUsageBar").font(.system(size: 12, weight: .semibold))
                    Text("偏好设置").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                } }.padding(.horizontal, 8).padding(.bottom, 5)
                VStack(spacing: 4) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Button { state.settingsTab = tab } label: {
                            Label(tab.title, systemImage: tab.symbol).font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                                .foregroundStyle(state.settingsTab == tab ? PanelPalette.primary : PanelPalette.secondary)
                                .background(state.settingsTab == tab ? PanelPalette.background : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .leading) { if state.settingsTab == tab { Capsule().fill(PanelPalette.shortRing).frame(width: 3, height: 16) } }
                        }.buttonStyle(.plain).accessibilityAddTraits(state.settingsTab == tab ? .isSelected : [])
                    }
                }
                Spacer()
                Text("设置偏好自动保存").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary).padding(.horizontal, 8)
            }.padding(.horizontal, 13).padding(.vertical, 24).frame(width: 190).background(PanelPalette.surface)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.settingsTab.title).font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        Text(state.settingsTab.subtitle).font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
                    }
                    Spacer()
                    Label("更改即时生效", systemImage: "circle.fill").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 12)
                settingsContent.id(state.settingsTab)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(PanelPalette.background)
        }
        .foregroundStyle(PanelPalette.primary).tint(PanelPalette.primary)
        .frame(width: 900, height: 720)
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
    private var accountsPage: some View {
        Form {
                Section("多账号管理") {
                    Button("添加账号") { state.addAccount() }.buttonStyle(OrbitActionStyle(prominent: true))
                    ForEach(state.orderedAccounts, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(state.accountRole(entry.id)).font(.headline)
                                Spacer()
                                if state.deletingAccountID == entry.id {
                                    ProgressView().controlSize(.small)
                                    Text("正在删除…").font(.caption).foregroundStyle(.secondary)
                                }
                                if entry.id != state.dualClient.activeProfileID {
                                    OrbitSwitchButton(owner: state, account: entry.state, controller: state.dualClient, profileID: entry.id)

                                    Button(role: .destructive) { state.requestAccountDeletion(entry.id) } label: {
                                        Label("删除账号", systemImage: "trash")
                                    }.buttonStyle(.borderless).foregroundStyle(Color.red)
                                        .disabled(!state.canDeleteAccount(entry.id))
                                }
                            }
                            SecondaryAccountSettingsView(state: entry.state)
                        }
                    }
                    Text("当前客户端登录用户为主账号，其余为备用账号。所有账号共用本地工作空间，登录凭证独立。")
                        .font(.caption).foregroundStyle(.secondary)
                }
        }.formStyle(.grouped).disabled(preview)
    }
    private var menuPage: some View {
        Form {
                Section("实时预览") {
                    HStack(spacing: 6) {
                        if state.preferences.isStacked {
                            Image(nsImage: MenuBarRenderer.stackedImage(
                                lines: QuotaPresentation.stackedLines(snapshot: state.displayedAccount.snapshot, preferences: state.preferences, verified: state.displayedAccount.verified, now: state.displayedAccount.now),
                                showIcon: state.preferences.showIcon,
                                colors: MenuBarRenderer.stackedColors(snapshot: state.displayedAccount.snapshot, preferences: state.preferences, verified: state.displayedAccount.verified, now: state.displayedAccount.now)))
                                .fixedSize()
                        } else {
                            if state.preferences.showIcon { Image(nsImage: ProviderIcon.codex()).resizable().renderingMode(.template).foregroundStyle(PanelPalette.primary).frame(width: 17, height: 17) }
                            Text(AttributedString(MenuBarRenderer.title(snapshot: state.displayedAccount.snapshot, preferences: state.preferences, verified: state.displayedAccount.verified, now: state.displayedAccount.now)))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    Text("修改立即应用到真正的 macOS 菜单栏。* 表示旧快照，-- 表示未知或重置待确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }


                Section("菜单栏显示内容") {
                    Toggle("显示菜单栏图标", isOn: bind(\.showIcon))
                    if state.preferences.showIcon {
                        HStack(spacing: 7) {
                            Image(nsImage: ProviderIcon.codex()).resizable().renderingMode(.template).foregroundStyle(PanelPalette.primary).frame(width: 18, height: 18)
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
                Section("百分比颜色联动") {
                    Toggle("额度卡片和账号列表跟随百分比颜色", isOn: bind(\.followsQuotaColors))
                }
                MenuColorRulesView(title: "5 小时百分比颜色", rules: Binding(
                    get: { state.preferences.primaryColorRules ?? [] }, set: { state.preferences.primaryColorRules = $0 }))
                MenuColorRulesView(title: "7 天百分比颜色", rules: Binding(
                    get: { state.preferences.secondaryColorRules ?? [] }, set: { state.preferences.secondaryColorRules = $0 }))

        }.formStyle(.grouped)
    }
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
                OrbitMark(size: 50).padding(.top, 24)
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
