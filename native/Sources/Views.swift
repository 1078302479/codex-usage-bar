import SwiftUI
import AppKit

@MainActor
struct QuotaPanelView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TidePanelHeader(owner: state, controller: state.dualClient)
            AppUpdateBanner(updates: state.appUpdates)
            ScrollView(.vertical) {
                OrbitPanelContent(owner: state, controller: state.dualClient, openSettings: openSettings)
                    .padding(.top, 4).padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(maxHeight: .infinity)
            if !state.accountPickerPresented { TidePanelFooter(owner: state, account: state.displayedAccount, openSettings: openSettings) }
        }
        .overlay(alignment: .bottom) { resizeHandle }
        .frame(width: OrbitLayout.panelWidth, height: state.panelHeight)
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            Task { @MainActor in state.panelContentMeasured(height) }
        }
        .onChange(of: state.accountPickerPresented) { _, _ in state.onPanelResize?(nil) }
        .font(TideTypography.body)
        .foregroundStyle(TidePalette.ink)
        .background(TidePalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .circular))
    }

    private var resizeHandle: some View {
        Color.clear.frame(width: 88, height: 5)
            .contentShape(Rectangle())
            .help("拖动调整弹窗高度")
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if state.panelDragStart == nil { state.panelDragStart = state.panelHeight }
                    state.onPanelResize?((state.panelDragStart ?? state.panelHeight) + value.translation.height)
                }
                .onEnded { _ in state.panelDragStart = nil })
    }
}

@MainActor
private struct TidePanelHeader: View {
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController

    var body: some View {
        let displayed = owner.displayedAccount
        let id = owner.homeAccounts.first { $0.state === displayed }?.id ?? "primary"
        let active = controller.detected && controller.activeProfileID == id
        HStack(spacing: 10) {
            Button { owner.accountPickerPresented.toggle() } label: {
                HStack(spacing: 10) {
                    TideAvatar(index: owner.tideAvatarIndex(id))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayed.snapshot?.accountLabel ?? "CodexUsageBar")
                            .font(TideTypography.account).foregroundStyle(TidePalette.ink).lineLimit(1)
                        HStack(spacing: 6) {
                            if active {
                                Circle().fill(TidePalette.green).frame(width: 6, height: 6)
                                    .background(TidePalette.green.opacity(0.25), in: Circle().inset(by: -3))
                            }
                            Text(active ? "当前登录" : (displayed.snapshot != nil ? "正在查看" : displayed.updateStatus.title))
                            if let plan = displayed.snapshot?.planType {
                                Text(plan.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.3)
                                    .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(LinearGradient(colors: [TidePalette.coral, TidePalette.indigo], startPoint: .leading, endPoint: .trailing),
                                                in: RoundedRectangle(cornerRadius: 5))
                            }
                        }.font(TideTypography.caption).foregroundStyle(TidePalette.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: owner.accountPickerPresented ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(TidePalette.tertiary)
                }
                .padding(.leading, 6).padding(.trailing, 10)
                .frame(height: 43)
                .background(TidePalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .circular))
            }.buttonStyle(.plain).accessibilityLabel("查看账号")
            Button { owner.refreshAllAccounts() } label: {
                if owner.isRefreshing { ProgressView().controlSize(.small).frame(width: 32, height: 32) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32) }
            }
            .buttonStyle(.plain).foregroundStyle(TidePalette.secondary)
            .background(TidePalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .circular))
            .disabled(owner.isRefreshing).keyboardShortcut("r").accessibilityLabel("刷新额度")
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        if !active, controller.detected, !owner.accountPickerPresented, displayed.snapshot != nil {
            Button("正在查看备用账号 · 返回当前") {
                owner.selectedAccountID = controller.activeProfileID
                owner.showingSecondAccountDetails = controller.activeSecondary
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(TidePalette.indigo).padding(.bottom, 6)
        }
    }
}

@MainActor
private struct TidePanelFooter: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    let openSettings: () -> Void

    var body: some View {
        let status = account.updateStatus
        HStack(spacing: 8) {
            Button(action: openSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape").font(.system(size: 9.5, weight: .regular))
                    Text("设置")
                    key("⌘,")
                }
            }.keyboardShortcut(",")
            Button { owner.refreshAllAccounts() } label: {
                HStack(spacing: 4) { Text("刷新"); key("⌘R") }
            }.disabled(owner.isRefreshing)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(status == .verified ? TidePalette.green : status.isWarning ? TidePalette.amber : TidePalette.tertiary)
                    .frame(width: 9, height: 9)
                Text((status == .verified ? account.lastSuccessfulAt ?? account.snapshot?.observedAt : nil)
                    .map { QuotaPresentation.time($0) + " " + status.title } ?? status.title)
                    .lineLimit(1)
            }.help(account.statusDetail)
            Button("退出") { NSApp.terminate(nil) }.padding(.leading, 5)
        }
        .buttonStyle(.plain).font(.system(size: 11.5, weight: .regular)).foregroundStyle(TidePalette.tertiary)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
    }

    private func key(_ title: String) -> some View {
        Text(title).font(TideTypography.mono).foregroundStyle(TidePalette.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(TidePalette.line))
    }
}

private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor
struct LoginItemSettingsView: View {
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
