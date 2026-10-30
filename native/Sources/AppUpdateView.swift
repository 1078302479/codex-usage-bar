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
                    Text("前往下载"); Image(systemName: "arrow.up.right")
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
            Text(updates.status).font(.caption).foregroundStyle(.secondary)
            if let date = updates.lastChecked {
                Text("上次检查：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(updates.checking ? "检查中…" : "立即检查更新") { updates.check() }.disabled(updates.checking)
                if updates.available { Button("下载最新版本") { updates.openDownload() } }
            }
            Text("启动后及每 8 小时检查一次 GitHub 正式版本。发现新版后点击下载入口打开发布页，不会自动安装或重启。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
