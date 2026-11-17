import SwiftUI

@MainActor
struct AppUpdateBanner: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        if updates.available {
            Button { updates.openDownload() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text("新版本 " + (updates.latest?.tag_name ?? ""))
                    Spacer()
                    Text("查看并更新"); Image(systemName: "chevron.right")
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(PanelPalette.link)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(PanelPalette.link.opacity(0.06))
            }.buttonStyle(.plain)
        }
    }
}

@MainActor
struct AppUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        Section("软件更新") {
            LabeledContent("当前版本", value: updates.currentVersion)
            Toggle("接收测试版", isOn: $updates.acceptsPrereleases).disabled(updates.busy || updates.readyToInstall)
            Text(updates.status).font(.caption).foregroundStyle(.secondary)
            if let report = updates.installationReport { Text(report).font(.caption).foregroundStyle(.secondary) }
            if let date = updates.lastChecked {
                Text("上次检查：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(updates.checking ? "检查中…" : "立即检查更新") { updates.check() }.disabled(updates.checking || updates.busy)
                if updates.available || updates.readyToInstall { Button("查看版本说明与更新") { updates.openDownload() } }
            }
            Text("启动时及每小时触发检查，距上次成功检查不足 24 小时则跳过。先查看版本说明，再下载校验，确认后安装并重启。测试版默认关闭。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct AppUpdateDetailView: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.app").font(.system(size: 32)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(updates.readyToInstall ? "更新已就绪" : "软件更新").font(.title2.bold())
                    Text("当前 \(updates.currentVersion) → \(updates.latest?.tag_name ?? "等待检查")").foregroundStyle(.secondary)
                }
                Spacer()
                if updates.latest?.prerelease == true { Text("测试版").font(.caption).padding(6).background(.orange.opacity(0.12), in: Capsule()) }
            }
            Toggle("接收测试版", isOn: $updates.acceptsPrereleases).disabled(updates.busy || updates.readyToInstall)
            Divider()
            Text("版本说明").font(.headline)
            ScrollView {
                Text(updates.latest?.body ?? "此版本未提供说明。")
                    .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if updates.busy { ProgressView().controlSize(.small) }
                Text(updates.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if updates.downloading {
                ProgressView(value: updates.downloadProgress)
                Text("\(Int(updates.downloadProgress * 100))%").font(.caption).monospacedDigit()
            }
            Text("安装会退出并重启 CodexUsageBar，不会重启 ChatGPT。旧版本保留为备份，账号及本地工作空间保留。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查更新") { updates.check() }.disabled(updates.checking || updates.busy || updates.readyToInstall)
                Spacer()
                if updates.readyToInstall { Button("查看安装文件") { updates.revealPreparedApp() } }
                if updates.downloading {
                    Button("取消下载") { updates.cancelDownload() }
                } else if updates.readyToInstall {
                    Button(updates.installing ? "正在安装…" : "安装并重启") { updates.install() }
                        .buttonStyle(.borderedProminent).disabled(updates.installing)
                } else if updates.available && !updates.canDownload {
                    Button("前往发布页下载") { updates.openReleasePage() }
                } else {
                    Button("下载并校验") { updates.download() }
                        .buttonStyle(.borderedProminent).disabled(!updates.available || updates.matchingArchive == nil || updates.checking)
                }
            }
        }.padding(24).frame(minWidth: 470, minHeight: 460)
    }
}
