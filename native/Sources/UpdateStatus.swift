import Foundation
import Network

struct RecoveryPolicy: Sendable {
    var retryDelays: [TimeInterval] = [5, 15, 30, 60, 120, 300]
    var mergeDelay: TimeInterval = 1
    var wakeDelay: TimeInterval = 2

    func delay(at attempt: Int) -> TimeInterval {
        retryDelays[min(max(0, attempt), retryDelays.count - 1)]
    }
}

enum UpdateStatus: Equatable {
    case waiting, checking, verified, stale, resetPending, sleeping
    case failed(CodexFailure)

    var title: String {
        switch self {
        case .waiting: return "尚未核验"
        case .checking: return "正在核验"
        case .verified: return "已核验"
        case .stale: return "数据已过期"
        case .resetPending: return "重置待确认"
        case .sleeping: return "休眠暂停"
        case .failed(let failure):
            switch failure {
            case .networkUnavailable: return "网络请求失败"
            case .serviceUnavailable: return "服务暂不可用"
            case .timeout: return "核验超时"
            case .processStopped: return "连接已断开"
            case .authRequired: return "需要登录"
            case .unsupported: return "版本不兼容"
            case .missingCLI: return "未找到 Codex"
            case .permissionDenied: return "启动被阻止"
            case .invalidResponse: return "数据无法识别"
            case .accountChanged: return "账号变化待核验"
            case .noQuota: return "暂无套餐额度"
            }
        }
    }
    var symbol: String {
        switch self {
        case .verified: return "checkmark.shield"
        case .waiting, .checking: return "arrow.triangle.2.circlepath"
        case .sleeping: return "moon"
        case .stale, .resetPending: return "clock"
        case .failed(.networkUnavailable): return "wifi.exclamationmark"
        case .failed(.authRequired): return "person.crop.circle.badge.exclamationmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
    var isWarning: Bool {
        switch self { case .stale, .resetPending, .failed: return true; default: return false }
    }
}

/// Reachability is a retry hint, not proof that the quota service is reachable.
final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    init(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { onChange($0.status == .satisfied) }
    }
    func start() { monitor.start(queue: DispatchQueue(label: "com.usagebar.connectivity", qos: .utility)) }
    func stop() { monitor.cancel() }
}
