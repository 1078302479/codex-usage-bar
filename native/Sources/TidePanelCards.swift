import SwiftUI

@MainActor
struct TideTank: View {
    @ObservedObject var account: AppState
    let window: QuotaWindow?
    let title: String
    let kind: TideQuotaKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let amount = QuotaPresentation.value(window, verified: account.verified && !account.isSigningOut, now: account.now)
        let remaining = amount == "--" ? nil : window?.remaining
        let fraction = (remaining ?? 0) / 100
        let liquid = kind.liquidColors(dark: scheme == .dark)
        let reset = QuotaPresentation.resetLabel(window, now: account.now)
        GeometryReader { frame in
            ZStack(alignment: .topLeading) {
                TidePalette.tank
                if fraction > 0 {
                    Canvas { context, size in
                        let level = size.height * (1 - fraction)
                        // Match the prototype's SVG: two periods across the card, with a 5 pt crest-to-trough height.
                        let center = level - 4
                        let segment = size.width / 4
                        let fill = Path { path in
                            path.move(to: CGPoint(x: 0, y: center))
                            for index in 0..<4 {
                                let x = CGFloat(index) * segment
                                path.addQuadCurve(to: CGPoint(x: x + segment, y: center),
                                                  control: CGPoint(x: x + segment / 2, y: center + (index.isMultiple(of: 2) ? -5 : 5)))
                            }
                            path.addLine(to: CGPoint(x: size.width, y: size.height))
                            path.addLine(to: CGPoint(x: 0, y: size.height))
                            path.closeSubpath()
                        }
                        context.fill(fill, with: .linearGradient(Gradient(colors: [liquid.surface, liquid.bottom]),
                            startPoint: CGPoint(x: 0, y: level), endPoint: CGPoint(x: 0, y: size.height)))
                    }.accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(kind.marker).frame(width: 7, height: 7)
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(TidePalette.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(amount.replacingOccurrences(of: "%", with: ""))
                            .font(.system(size: 46, weight: .heavy)).tracking(-2)
                        if remaining != nil { Text("%").font(.system(size: 18, weight: .bold)).opacity(0.6) }
                    }.monospacedDigit().foregroundStyle(fraction > 0.78 ? Color.white : TidePalette.ink)
                }.padding(.leading, 16).padding(.top, 13)
                VStack(alignment: .leading, spacing: 3) {
                    if let date = window?.resetDate, date > account.now, account.verified {
                        Text(tideDuration(date.timeIntervalSince(account.now))).font(.system(size: 13, weight: .bold))
                        Text("后重置 · " + (sameBeijingDay(date, account.now) ? QuotaPresentation.time(date) : String(ResetCreditSummary.expiryLabel(date).dropFirst(5))))
                            .font(TideTypography.caption).lineLimit(1).minimumScaleFactor(0.75)
                    } else {
                        Text(reset).font(TideTypography.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }.monospacedDigit().foregroundStyle(fraction > 0.26 ? Color.white.opacity(0.92) : TidePalette.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, fraction > 0.26 ? 12 : frame.size.height * fraction + 14)
            }.clipShape(RoundedRectangle(cornerRadius: 24, style: .circular))
        }.frame(height: 178)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + "，剩余 " + amount + "，" + reset)
    }

    private func sameBeijingDay(_ date: Date, _ now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.isDate(date, inSameDayAs: now)
    }
}

func tideDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(max(0, min(4_300_000_000, seconds / 60)).rounded(.up))
    let hours = minutes / 60
    if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小时" }
    if hours > 0 { return "\(hours) 小时 \(minutes % 60) 分" }
    return "\(minutes) 分钟"
}

private struct TideCard<Content: View>: View {
    var spacing: CGFloat = 8
    var bottomPadding: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TidePalette.card, in: RoundedRectangle(cornerRadius: 18, style: .circular))
    }
}

@MainActor
struct TideForecastCard: View {
    let projection: TideQuotaHistory.Projection?
    let reset: Date?
    let windowLabel: String
    let recommendation: (id: String, label: String, remaining: Double)?
    let select: (String) -> Void

    var body: some View {
        TideCard(spacing: 4, bottomPadding: 11.5) {
            HStack {
                Text("用完预测 · 最近 30 分钟")
                    .font(TideTypography.subheading).foregroundStyle(TidePalette.secondary)
                Spacer(minLength: 2)
                if let recommendation {
                    Button("切换到 \(recommendation.label) · \(QuotaPresentation.percent(recommendation.remaining)) →") { select(recommendation.id) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(TidePalette.indigo.opacity(0.14), in: Capsule()).foregroundStyle(TidePalette.indigo)
                } else if let projection, projection.exhaustion == nil {
                    Text("✓ 节奏安全").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(TidePalette.green.opacity(0.15), in: Capsule()).foregroundStyle(TidePalette.green)
                }
            }.frame(minHeight: 25)
            Group {
                if let projection {
                    if let end = projection.exhaustion {
                        let time = Text(QuotaPresentation.time(end) + " 用完").bold().foregroundColor(TidePalette.red)
                        Text("按当前速度，\(windowLabel) 额度会在 \(time)，比重置早 \(tideDuration(projection.reset.timeIntervalSince(end)))。")
                    } else {
                        let remaining = projection.remainingAtReset
                        let rounded = remaining.rounded()
                        let percent = QuotaPresentation.percent(abs(remaining - rounded) < 0.05 && (1...99).contains(rounded) ? rounded : remaining)
                        let amount = Text(percent).bold().foregroundColor(TidePalette.green)
                        Text("按当前速度，重置时大约还剩 \(amount)，可以放心用。")
                    }
                } else {
                    Text("正在收集用量，样本充足后显示预测。")
                        .font(.system(size: 13, weight: .regular)).foregroundStyle(TidePalette.secondary)
                }
            }.frame(minHeight: 19.5, alignment: .topLeading)
            TideProjectionChart(projection: projection, reset: reset).frame(height: 76).padding(.top, 4)
        }.font(TideTypography.body).foregroundStyle(TidePalette.ink).lineSpacing(3)
    }


}

private struct TideProjectionChart: View {
    let projection: TideQuotaHistory.Projection?
    let reset: Date?

    var body: some View {
        Canvas { context, size in
            let width = max(1, size.width - 16)
            let floor = size.height - 12
            guard let projection, let first = projection.samples.first, let last = projection.samples.last else {
                drawAxes(context, width: width, floor: floor, reset: reset)
                return
            }
            let total = max(1, projection.reset.timeIntervalSince(first.date))
            let observed = last.date.timeIntervalSince(first.date)
            let middle = width * CGFloat(observed / total)
            let range = max(12, first.remaining)
            func height(_ remaining: Double) -> CGFloat { 6 + (floor - 6) * CGFloat((first.remaining - remaining) / range) }
            let points = projection.samples.map { sample in
                CGPoint(x: middle * CGFloat(sample.date.timeIntervalSince(first.date) / observed), y: min(floor, height(sample.remaining)))
            }
            guard let start = points.first, let current = points.last else { return }
            let color = projection.exhaustion == nil ? TidePalette.coral : TidePalette.red
            var line = Path(); line.move(to: start)
            for point in points.dropFirst() { line.addLine(to: point) }
            var area = line; area.addLine(to: CGPoint(x: current.x, y: floor)); area.addLine(to: CGPoint(x: 0, y: floor)); area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                                                      startPoint: start, endPoint: CGPoint(x: 0, y: floor)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            let timeAfterCurrent = projection.reset.timeIntervalSince(last.date)
            let x = projection.exhaustion.map { date -> CGFloat in
                let fraction = date.timeIntervalSince(last.date) / timeAfterCurrent
                return middle + (width - middle) * CGFloat(min(1, max(0, fraction)))
            } ?? width
            let end = CGPoint(x: x, y: min(floor, height(projection.remainingAtReset)))
            context.stroke(Path { $0.move(to: current); $0.addLine(to: end) }, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
            drawAxes(context, width: width, floor: floor, reset: projection.reset)
            let dot = Path(ellipseIn: CGRect(x: current.x - 4, y: current.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(TidePalette.card))
            context.stroke(dot, with: .color(color), lineWidth: 2)
            if let exhaustion = projection.exhaustion {
                context.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(color))
                context.draw(Text(QuotaPresentation.time(exhaustion) + " 用完").font(.system(size: 9.5, weight: .bold)).foregroundColor(color),
                             at: CGPoint(x: min(width - 27, max(27, end.x)), y: end.y - 11))
            }
            context.draw(Text(QuotaPresentation.time(first.date)).font(.system(size: 9.5)).foregroundColor(TidePalette.tertiary), at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
            context.draw(Text("现在").font(.system(size: 9.5, weight: .semibold)).foregroundColor(TidePalette.secondary), at: CGPoint(x: min(width - 94, max(40, middle)), y: size.height), anchor: .bottom)
        }.accessibilityLabel(projection == nil ? "额度趋势等待样本" : "额度趋势。实线是近期实际额度变化，虚线是预测。")
    }

    private func drawAxes(_ context: GraphicsContext, width: CGFloat, floor: CGFloat, reset: Date?) {
        context.stroke(Path { path in
            path.move(to: CGPoint(x: 0, y: floor))
            path.addLine(to: CGPoint(x: width, y: floor))
        }, with: .color(TidePalette.line))
        if let reset {
            context.stroke(Path { path in
                path.move(to: CGPoint(x: width, y: 4))
                path.addLine(to: CGPoint(x: width, y: floor))
            }, with: .color(TidePalette.tertiary), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            context.draw(Text(QuotaPresentation.time(reset) + " 重置").font(.system(size: 9.5, weight: .regular))
                .foregroundColor(TidePalette.tertiary), at: CGPoint(x: width, y: floor + 12), anchor: .bottomTrailing)
        }
    }
}

@MainActor
struct TideCreditsCard: View {
    @ObservedObject var account: AppState
    let openSettings: () -> Void


    var body: some View {
        let summary = account.verified ? account.snapshot?.resetCredits : nil
        let tickets = summary?.availableDetails ?? []
        TideCard(spacing: 10) {
            HStack {
                Text("重置卡" + (summary?.availableCount.map { " · \($0) 张可用" } ?? ""))
                    .font(TideTypography.section).foregroundStyle(TidePalette.secondary)
                Spacer()
                Button(action: openSettings) {
                    HStack(spacing: 4) {
                        Text("🔔").accessibilityHidden(true)
                        Text("提前 24h 提醒")
                    }.font(TideTypography.metadata)
                }.buttonStyle(.plain).foregroundStyle(TidePalette.tertiary)
                    .help("打开提醒设置。提醒跟随当前登录账号。")
            }.frame(minHeight: 16.5)
            if tickets.isEmpty {
                Text(summary?.availableCount == 0 ? "当前没有可用重置卡。" : "重置卡到期时间待核验")
                    .font(.system(size: 11)).foregroundStyle(TidePalette.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(tickets.prefix(3)) { credit in ticket(credit) }
                    ForEach(0..<max(0, 3 - tickets.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
                if tickets.count > 3 {
                    Button(account.resetCreditsExpanded ? "收起明细" : "查看全部 \(tickets.count) 张") { account.resetCreditsExpanded.toggle() }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                if account.resetCreditsExpanded {
                    ForEach(tickets.dropFirst(3)) { credit in
                        Text(credit.expiryDate.map(ResetCreditSummary.expiryLabel) ?? "到期时间待核验")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            if account.isStale || (summary?.availableCount ?? 0) > tickets.count {
                Text(account.isStale ? "上次核验记录" : "部分到期日期待核验")
                    .font(.system(size: 10)).foregroundStyle(TidePalette.secondary)
            }
        }
    }

    private func ticket(_ credit: ResetCredit) -> some View {
        let seconds = credit.expiryDate?.timeIntervalSince(account.now)
        let hot = seconds.map { $0 > 0 && $0 <= 72 * 3600 } ?? false
        let days = seconds.flatMap { $0 > 0 ? Int($0 / 86400) : nil }
        let date = credit.expiryDate.map { String(ResetCreditSummary.expiryLabel($0).dropFirst(5)) } ?? "日期待核验"
        return VStack(alignment: .leading, spacing: 10.5) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let days {
                    Text(days == 0 ? "<1" : "\(days)").font(.system(size: 20, weight: .heavy)).tracking(-0.5)
                    Text("天").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hot ? Color.white.opacity(0.85) : TidePalette.secondary)
                } else { Text(seconds == nil ? "待确认" : "已到期").font(.system(size: 13, weight: .semibold)) }
            }.monospacedDigit()
            Text(date).font(TideTypography.mono).lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(hot ? Color.white.opacity(0.85) : TidePalette.tertiary)
        }
        .foregroundStyle(hot ? Color.white : TidePalette.ink)
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 8)
        .frame(maxWidth: .infinity, minHeight: 64.5, alignment: .topLeading)
        .background {
            if hot { LinearGradient(colors: [TidePalette.coral, TidePalette.color(0xFF4D7A)], startPoint: .topLeading, endPoint: .bottomTrailing) }
            else { TidePalette.surface }
        }
        .overlay {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: 10, y: geometry.size.height * 0.62))
                    path.addLine(to: CGPoint(x: geometry.size.width - 10, y: geometry.size.height * 0.62))
                }.stroke(hot ? Color.white.opacity(0.4) : TidePalette.line, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                ForEach([CGFloat.zero, geometry.size.width], id: \.self) { x in
                    Circle().fill(TidePalette.card).frame(width: 12, height: 12)
                        .position(x: x, y: geometry.size.height * 0.62)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
        .help(credit.expiryDate.map { ResetCreditSummary.expiryLabel($0) + " · 北京时间" } ?? date)
    }
}

@MainActor
struct TideActivityCard: View {
    @ObservedObject var account: AppState
    @StateObject private var interaction = Interaction()
    private final class Interaction: ObservableObject { @Published var details = false }

    var body: some View {
        TideCard {
            HStack {
                Text("Token 活动").font(TideTypography.section).foregroundStyle(TidePalette.secondary)
                Spacer()
                if let date = account.activityUpdatedAt {
                    Button("官方统计 · " + QuotaPresentation.time(date)) { interaction.details.toggle() }.buttonStyle(.plain)
                        .font(TideTypography.metadata).foregroundStyle(TidePalette.tertiary).help("打开完整 Token 活动")
                }
            }.frame(minHeight: 16.5)
            if account.verified, let activity = account.tokenActivity {
                let summary = activity.summary
                HStack(alignment: .top, spacing: 0) {
                    metric(Text(TokenActivity.count(summary?.lifetimeTokens)), "累计")
                    metric(Text(TokenActivity.count(summary?.peakDailyTokens)), "单日峰值")
                    metric(streak(summary), "连续 / 最长")
                    metric(Text(turn(summary?.longestRunningTurnSec)), "最长单轮")
                }
                if activity.dailyUsageBuckets != nil {
                    ActivityHeatmap(activity: activity, now: account.now, compact: true)
                        .frame(height: 64).padding(.top, 3)
                }
            } else {
                Text(account.activityError ?? "尚未取得账号统计").font(.system(size: 11)).foregroundStyle(TidePalette.secondary)
            }
        }.sheet(isPresented: $interaction.details) {
            VStack {
                TokenActivityView(state: account)
                Button("关闭") { interaction.details = false }.keyboardShortcut(.cancelAction)
            }.padding(14).frame(width: 420).background(TidePalette.background)
        }
    }

    private func metric(_ value: Text, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            value.font(TideTypography.metric).tracking(-0.5)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(TidePalette.ink)
            Text(label).font(.system(size: 10.5, weight: .regular)).foregroundStyle(TidePalette.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func streak(_ summary: TokenActivity.Summary?) -> Text {
        guard let current = TokenActivity.valid(summary?.currentStreakDays),
              let longest = TokenActivity.valid(summary?.longestStreakDays) else { return Text("—") }
        let suffix = Text(" / " + TokenActivity.count(longest) + " 天").font(.system(size: 11, weight: .bold))
        return Text("\(TokenActivity.count(current))\(suffix)")
    }

    private func turn(_ value: Double?) -> String {
        guard let value = TokenActivity.valid(value), value < Double(Int.max) else { return "—" }
        let seconds = Int(value)
        return seconds >= 3600 ? TokenActivity.duration(value) : "\(seconds / 60)′\(seconds % 60)″"
    }
}
