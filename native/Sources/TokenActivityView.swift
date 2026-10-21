import SwiftUI

@MainActor
struct TokenActivityView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Token 活动").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("账号累计").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if state.verified, let activity = state.tokenActivity {
                HStack(alignment: .top, spacing: 0) {
                    headline("累计 Token", TokenActivity.count(activity.summary?.lifetimeTokens))
                    Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1, height: 42).padding(.horizontal, 20)
                    headline("单日峰值", TokenActivity.count(activity.summary?.peakDailyTokens))
                }
                HStack(spacing: 0) {
                    compact("当前连续", TokenActivity.days(activity.summary?.currentStreakDays))
                    Spacer(minLength: 12)
                    compact("最长连续", TokenActivity.days(activity.summary?.longestStreakDays))
                }
                HStack {
                    Text("最长单轮").foregroundStyle(.secondary)
                    Spacer()
                    Text(TokenActivity.duration(activity.summary?.longestRunningTurnSec)).monospacedDigit()
                }.font(.system(size: 11))
                Divider()
                if activity.dailyUsageBuckets != nil {
                    HStack {
                        Text("每日用量").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("近半年").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ActivityHeatmap(activity: activity, now: state.now).frame(height: 138)
                } else {
                    Text("暂未返回每日数据").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Label("官方统计", systemImage: "checkmark.shield").font(.system(size: 9))
                    Spacer()
                    if let date = state.activityUpdatedAt {
                        Text(QuotaPresentation.time(date) + " 更新").font(.system(size: 9)).monospacedDigit()
                    }
                }.foregroundStyle(.tertiary)
            } else {
                Text(state.isRefreshing ? "正在获取统计…" : "尚未取得账号统计")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = state.activityError { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
        }
        .padding(.top, 18)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1) }
        .padding(.horizontal, 20).padding(.bottom, 18)
    }
    private func headline(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func compact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
        }.font(.system(size: 11)).accessibilityElement(children: .combine)
    }
}
