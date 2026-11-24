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
                VStack(alignment: .leading, spacing: 5) {
                    Text("累计 Token").font(.system(size: 12)).foregroundStyle(PanelPalette.secondary)
                    HStack {
                        Text(TokenActivity.count(activity.summary?.lifetimeTokens)).font(.system(size: 34, weight: .medium))
                        Spacer()
                        Text("官方活动统计").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                    }
                }
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        compact("单日峰值", TokenActivity.count(activity.summary?.peakDailyTokens))
                        compact("最长单轮", TokenActivity.duration(activity.summary?.longestRunningTurnSec))
                    }
                    GridRow {
                        compact("当前连续", TokenActivity.days(activity.summary?.currentStreakDays))
                        compact("最长连续", TokenActivity.days(activity.summary?.longestStreakDays))
                    }
                }
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
        .padding(13)
        .orbitCard()
    }
    private func compact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(PanelPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(PanelPalette.border) }
        .accessibilityElement(children: .combine)
    }
}
