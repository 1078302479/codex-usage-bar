import Combine
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: return "已开启，登录 macOS 后自动启动"
        case .requiresApproval: return "等待系统批准，请在“登录项”中允许 CodexUsageBar"
        case .notRegistered: return "已关闭"
        case .notFound: return "找不到应用，请将 CodexUsageBar 放在固定位置后重试"
        @unknown default: return "暂时无法确认系统状态"
        }
    }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true; errorMessage = nil
        Task {
            defer { refresh(); isUpdating = false }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "设置未完成：" + error.localizedDescription
            }
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
