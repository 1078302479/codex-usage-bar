import SwiftUI

@MainActor
struct ResetCreditReminderSettingsView: View {
    @ObservedObject var controller: ResetCreditReminderController
    @ObservedObject var lowQuota: LowQuotaReminderController

    var body: some View {
        Form {
            Section("用完预测") {
                Toggle("预计在重置前用完时提醒", isOn: Binding(get: { lowQuota.forecastEnabled }, set: { value in
                    Task { await lowQuota.setForecastEnabled(value) }
                })).disabled(lowQuota.isUpdating)
                Text("根据最近 30 分钟的已核验额度估算，仅提醒当前登录账号。")
                    .font(.caption).foregroundStyle(.secondary)
                if lowQuota.permission == .denied {
                    Button("在系统设置中允许通知") { controller.openSystemSettings() }
                }
            }
            Section("低额度提醒") {
                Toggle("剩余额度达到阈值时提醒", isOn: Binding(get: { lowQuota.enabled }, set: { value in
                    Task { await lowQuota.setEnabled(value) }
                })).disabled(lowQuota.isUpdating)
                Picker("提醒阈值", selection: Binding(get: { lowQuota.threshold }, set: { lowQuota.setThreshold($0) })) {
                    ForEach(LowQuotaReminderController.thresholds, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }.disabled(lowQuota.isUpdating)
                Text("当前登录账号的每个额度窗口在每次重置前最多提醒一次。")
                    .font(.caption).foregroundStyle(.secondary)
                if lowQuota.permission == .denied {
                    Button("在系统设置中允许通知") { controller.openSystemSettings() }
                } else if lowQuota.permission == .unavailable {
                    Text("当前运行方式不支持通知。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("重置卡到期提醒") {
                Toggle("到期前 24 小时提醒", isOn: Binding(get: { controller.enabled }, set: { value in
                    Task { await controller.setEnabled(value) }
                })).disabled(controller.isUpdating)
                Text("首次开启时请求 macOS 通知权限。通知只包含到期时间，不包含账号信息，也不会自动使用重置卡。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("系统通知", value: permissionLabel)
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
                if controller.permission == .denied {
                    Button("打开系统通知设置") { controller.openSystemSettings() }
                }
            }
            Section("提醒规则") {
                Text("每张卡在到期前 24 小时提醒一次；开启或唤醒时若已进入 24 小时范围，会在成功核验后补提醒。")
                Text("同一账号、同一卡片的提醒会持久去重。发现卡片已使用、过期或账号变化后，取消对应提醒。只有数量而没有到期时间时不推算日期。")
                Text("开启提醒后每 15 分钟核验卡片状态，并在已知提醒时刻前额外核验；手动刷新可立即确认其他设备的变化。")
            }.font(.caption)
            Section("系统投递") {
                Text("已安排的本地通知在正常退出应用后仍可投递。通知基于最近一次成功核验，其他设备用卡后须再次核验才能取消。电脑关机、休眠或专注模式可能让提醒延后。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onAppear { controller.refreshPermission() }
        .task { await lowQuota.refreshPermission() }
    }
    private var permissionLabel: String {
        switch controller.permission {
        case .unknown: return "尚未申请"
        case .allowed: return "已允许"
        case .denied: return "未允许"
        case .unavailable: return "当前运行方式不支持"
        }
    }
}
