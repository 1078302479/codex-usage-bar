import SwiftUI
import AppKit

@MainActor
struct QuotaPanelView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            AppUpdateBanner(updates: state.appUpdates)
            panelScroll
            Divider()
            panelFooter
        }
        .alert("删除账号？", isPresented: Binding(get: { state.pendingAccountDeletion != nil }, set: { if !$0 { state.cancelAccountDeletion() } })) {
            Button("取消", role: .cancel) { state.cancelAccountDeletion() }
            Button("确认删除", role: .destructive) { state.confirmAccountDeletion() }
        } message: {
            Text("将退出并移除该账号，重新使用时需要登录。本地项目、聊天和模型配置会保留。")
        }
        .overlay(alignment: .bottom) { resizeHandle }
        .frame(width: OrbitLayout.panelWidth, height: state.panelHeight)
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            Task { @MainActor in state.panelContentMeasured(height) }
        }
        .foregroundStyle(PanelPalette.primary)
        .tint(PanelPalette.link)
        .background(PanelPalette.background)
    }

    private var panelHeader: some View {
        HStack(spacing: 9) {
            OrbitMark()
            Text("CodexUsageBar").font(.system(size: 13, weight: .medium))
            Spacer()
            PanelMonitorStatus(account: state.displayedAccount)
            if state.isRefreshing { ProgressView().controlSize(.small) }
            Button { state.refreshAllAccounts() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(PanelPalette.secondary).disabled(state.isRefreshing)
                .help("核验所有账号额度").accessibilityLabel("核验所有账号额度")


        }.padding(.horizontal, OrbitLayout.inset).padding(.vertical, 10)
    }

    private var panelScroll: some View {
        ScrollView(.vertical) { panelContent }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelPalette.panelBackdrop)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            OrbitPanelContent(owner: state, controller: state.dualClient, openSettings: openSettings)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
        })
    }

    private var panelFooter: some View {
        HStack {
            Button(action: openSettings) { Label("显示与连接设置…", systemImage: "slider.horizontal.3") }
                .buttonStyle(OrbitActionStyle()).accessibilityLabel("打开 CodexUsageBar 设置")
            Spacer()
            Label(state.displayedAccount.updateStatus.title, systemImage: state.displayedAccount.updateStatus.symbol)
                .font(.system(size: 9)).foregroundStyle(state.displayedAccount.updateStatus.isWarning ? PanelPalette.warning : PanelPalette.secondary)
                .help(state.displayedAccount.statusDetail)
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
        }.font(.system(size: 11)).foregroundStyle(PanelPalette.secondary).padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var resizeHandle: some View {
        Capsule().fill(PanelPalette.secondary.opacity(0.4)).frame(width: 30, height: 3)
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

}

private struct PanelMonitorStatus: View {
    @ObservedObject var account: AppState

    var body: some View {
        let status = account.updateStatus
        HStack(spacing: 5) {
            Circle()
                .fill(status == .verified ? PanelPalette.success : status.isWarning ? PanelPalette.warning : PanelPalette.secondary)
                .frame(width: 5, height: 5)
            Text(status == .verified ? "实时监测" : status.title)
                .font(.system(size: 10))
                .foregroundStyle(PanelPalette.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(PanelPalette.surface, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度监测，" + status.title)
        .help(account.statusDetail)
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
