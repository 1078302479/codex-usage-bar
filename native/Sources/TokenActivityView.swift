import SwiftUI

@MainActor
struct TokenActivityView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Token 活动").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(state.activityUpdatedAt.map { "官方统计 " + QuotaPresentation.time($0) } ?? "官方统计")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(PanelPalette.secondary)
                    .help("当前账号的官方 Token 活动统计；时间为最近一次统计更新时间")
            }
            if state.verified, let activity = state.tokenActivity {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        headline("累计 Token", TokenActivity.count(activity.summary?.lifetimeTokens), symbol: "sum")
                        headline("单日峰值", TokenActivity.count(activity.summary?.peakDailyTokens), symbol: "chart.line.uptrend.xyaxis")
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 6) {
                        compact("当前连续", TokenActivity.days(activity.summary?.currentStreakDays))
                        compact("最长连续", TokenActivity.days(activity.summary?.longestStreakDays))
                        compact("最长单轮", TokenActivity.duration(activity.summary?.longestRunningTurnSec))
                    }
                }
                .padding(.vertical, 8)
                if activity.dailyUsageBuckets != nil {
                    HStack {
                        Text("每日用量").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("近半年").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                    }
                    ActivityHeatmap(activity: activity, now: state.now).frame(height: 138)
                } else {
                    Text("暂未返回每日数据").font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
                }
            } else {
                Text(state.isRefreshing ? "正在获取统计…" : "尚未取得账号统计")
                    .font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
            }
            if let error = state.activityError { Text(error).font(.system(size: 10)).foregroundStyle(PanelPalette.warning) }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1) }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }
    private func headline(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private func compact(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
            Text(title).font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
        }.frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
