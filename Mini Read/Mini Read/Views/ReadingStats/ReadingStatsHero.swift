//
//  ReadingStatsHero.swift
//  TheNewVellium
//
//  统计页首屏：今天读了多少、连着读了几天、最近两周稳不稳。
//
//  刻意不放累计小时数当主角：那是个只会变大、不会给下一步动作的数字。
//  累计退到副标题，够用就好。
//

import SwiftUI

// MARK: - 今日

struct ReadingStatsHero: View {

    /// `nil` = 数据还没算好。此时数字显示「—」，布局不跳。
    let overview: ReadingStatsOverview?
    let accent: Color
    /// 近 14 天柱高。iPad 宽版把卡片拉宽后，44pt 会变成一条扁带，
    /// 这里让调用方按可用宽度给一个更合适的高度。
    var sparklineHeight: CGFloat = 44
    /// 主数字的额外倍率。iPad 宽版卡片更宽，52pt 会显得不够压场。
    var numberScale: CGFloat = 1
    /// 宽版下与右侧栏共享的高度。
    ///
    /// 「继续阅读 + 书架进度」两张卡的总高由内容决定，Hero 的高度也由内容决定；
    /// 两者差十几到几十 pt 时，右栏底边会悬在 Hero 上方。这里让调用方把右栏
    /// 量到的高度传进来，Hero 用 `minHeight` 补齐，再用 `stretches` 把 14 天
    /// 柱推到底部——两张卡的最后一条边就落在同一条线上。
    var minHeight: CGFloat = 0
    /// 是否允许把内容撑开（宽版为 true）。紧凑版不加 Spacer，布局保持原样。
    var stretches: Bool = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 首屏数字跟着 Dynamic Type 一起长，而不是钉死在 52pt。
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 52

    private var accentText: Color { StatsPalette.readable(accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            number
            caption

            if stretches {
                // 只在宽版出现：把 14 天柱推到底部，Hero 被右栏撑高时
                // 多出来的空间落在数字与柱图之间，而不是柱图下面。
                Spacer(minLength: 0)
            }

            sparkline
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
        .background(background)
        .accessibilityElement(children: .contain)
    }

    // MARK: 顶部

    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                todayLabel
                streakBadge
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                todayLabel
                Spacer(minLength: 8)
                streakBadge
            }
        }
    }

    private var todayLabel: some View {
        Text("今日阅读")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(StatsPalette.secondaryText)
            .accessibilityHidden(true)
    }

    // MARK: 主数字

    private var number: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(todayValue)
                .font(.system(size: numberSize * numberScale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(todayUnit)
                .font(.title3.weight(.medium))
                .foregroundStyle(StatsPalette.secondaryText)
                .lineLimit(1)
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.35),
            value: overview?.todaySeconds
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日阅读")
        .accessibilityValue(overview == nil ? "正在统计" : "\(todayValue) \(todayUnit)")
        // 视觉上连续天数在右上角，但它不该抢在今日时长之前被读出来。
        .accessibilitySortPriority(3)
    }

    private var todayValue: String {
        guard let seconds = overview?.todaySeconds else { return "—" }
        let minutes = Int((Double(seconds) / 60).rounded())
        guard minutes >= 600 else { return "\(minutes)" }
        return String(format: "%.1f", Double(minutes) / 60)
    }

    private var todayUnit: String {
        guard let seconds = overview?.todaySeconds else { return "分钟" }
        return Int((Double(seconds) / 60).rounded()) >= 600 ? "小时" : "分钟"
    }

    private var caption: some View {
        Text(captionText)
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(StatsPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilitySortPriority(1)
    }

    private var captionText: String {
        guard let overview else { return " " }
        guard overview.totalSeconds > 0 else {
            return "读上几分钟，今天就会出现在这里"
        }
        return "本周 \(StatsFormat.duration(overview.weekSeconds)) · 累计 \(StatsFormat.duration(overview.totalSeconds))"
    }

    // MARK: 连续天数

    @ViewBuilder
    private var streakBadge: some View {
        if let streak = overview?.currentStreak, streak > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)

                Text("\(streak) 天")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(accentText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("连续阅读 \(streak) 天")
            .accessibilitySortPriority(2)
        }
    }

    // MARK: 近 14 天

    private var sparkline: some View {
        let days = overview?.recentDays ?? []
        // 用 15 分钟作为刻度下限：只有几十秒记录时，按峰值归一化会把
        // 那一条画成满格，看起来像「读了一整天」。
        let scale = max(days.map(\.seconds).max() ?? 0, 15 * 60)

        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(fillColor(for: day))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(for: day, scale: scale))
                }
            }
            .frame(height: sparklineHeight, alignment: .bottom)

            captionRow(days)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 14 天阅读趋势")
        .accessibilityValue(summary(days))
    }

    /// 大字号下「近 14 天」和「日均 39 分」并排会互相挤到换行，
    /// 改成上下两行——这两句都不是可以截断的装饰。
    @ViewBuilder
    private func captionRow(_ days: [ReadingStatsDay]) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text("近 14 天")
                    .font(.caption)
                    .foregroundStyle(StatsPalette.tertiaryText)

                if !days.isEmpty {
                    Text("日均 \(StatsFormat.duration(average(days)))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(StatsPalette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("近 14 天")
                    .font(.caption)
                    .foregroundStyle(StatsPalette.tertiaryText)

                Spacer(minLength: 8)

                if !days.isEmpty {
                    Text("日均 \(StatsFormat.duration(average(days)))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(StatsPalette.secondaryText)
                }
            }
        }
    }

    private func fillColor(for day: ReadingStatsDay) -> Color {
        guard day.seconds > 0 else { return Color.primary.opacity(0.07) }
        return day.isToday ? accent : accent.opacity(0.45)
    }

    private func barHeight(for day: ReadingStatsDay, scale: Int) -> CGFloat {
        guard day.seconds > 0 else { return 4 }
        let ratio = CGFloat(day.seconds) / CGFloat(max(scale, 1))
        return max(5, sparklineHeight * ratio)
    }

    private func average(_ days: [ReadingStatsDay]) -> Int {
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + $1.seconds } / days.count
    }

    private func summary(_ days: [ReadingStatsDay]) -> String {
        guard let peak = days.max(by: { $0.seconds < $1.seconds }), peak.seconds > 0 else {
            return "最近 14 天还没有阅读记录"
        }
        return "日均 \(StatsFormat.duration(average(days)))，最多的一天是 \(StatsFormat.day(peak.date))，\(StatsFormat.duration(peak.seconds))"
    }

    // MARK: 背景

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        // 暗色下需要更高的染色浓度，否则渐变会消失在 #1C1C1E 里。
        let topOpacity = colorScheme == .dark ? 0.22 : 0.14

        return shape
            .fill(StatsPalette.cardFill)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [accent.opacity(topOpacity), accent.opacity(0.01)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.strokeBorder(StatsPalette.hairline, lineWidth: 0.5)
            }
    }
}

// MARK: - 当前在读

/// 「还想继续读」的唯一入口：一本书、一个进度、一个还要多久。
///
/// 刻意不做成可点击——跳转阅读器要走书架的封面缩放转场，
/// 这里半途接一个没有转场的入口，会把「从封面进入阅读」的观感打散。
struct CurrentBookCard: View {

    let book: ReadingStatsCurrentBook
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 44

    private var accentText: Color { StatsPalette.readable(accent) }

    private var coverSize: CGSize {
        let width = min(coverWidth, 64)
        return CGSize(width: width, height: width * 1.4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .top, spacing: 14) {
                StatsCover(
                    url: book.coverURL,
                    size: coverSize,
                    cornerRadius: 6
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.footnote)
                            .foregroundStyle(StatsPalette.secondaryText)
                            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    }

                    progress
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .statsCardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                sectionLabel
                relativeTime
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel
                Spacer(minLength: 8)
                relativeTime
            }
        }
    }

    private var sectionLabel: some View {
        Text(book.isFinished ? "最近阅读" : "继续阅读")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(StatsPalette.secondaryText)
    }

    private var relativeTime: some View {
        Text(StatsFormat.relative(book.lastRead))
            .font(.caption)
            .foregroundStyle(StatsPalette.tertiaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    private var progress: some View {
        if let value = book.progress {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    StatsBar(fraction: value, accent: accent, height: 4)
                    progressCaption(value)
                }
            } else {
                HStack(spacing: 8) {
                    StatsBar(fraction: value, accent: accent, height: 4)
                        .frame(maxWidth: 150)

                    progressCaption(value)
                }
            }
        } else {
            Text("进度未统计")
                .font(.caption)
                .foregroundStyle(StatsPalette.tertiaryText)
        }
    }

    @ViewBuilder
    private func progressCaption(_ value: Double) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    percentLabel(value)
                    finishedMark
                }

                if let remaining = book.remainingSeconds {
                    remainingLabel(remaining)
                }
            }
        } else {
            HStack(spacing: 6) {
                percentLabel(value)
                finishedMark

                if let remaining = book.remainingSeconds {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(StatsPalette.tertiaryText)
                        .accessibilityHidden(true)

                    remainingLabel(remaining)
                }
            }
        }
    }

    private func percentLabel(_ value: Double) -> some View {
        Text(StatsFormat.percent(value))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(StatsPalette.secondaryText)
    }

    @ViewBuilder
    private var finishedMark: some View {
        if book.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(accentText)
                .accessibilityHidden(true)
        }
    }

    private func remainingLabel(_ seconds: Int) -> some View {
        Text(StatsFormat.remaining(seconds))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(StatsPalette.secondaryText)
            .lineLimit(1)
    }

    private var accessibilityLabel: String {
        var parts = [book.isFinished ? "最近阅读" : "继续阅读", book.title]
        if !book.author.isEmpty { parts.append(book.author) }
        if let progress = book.progress {
            parts.append(book.isFinished ? "已读完" : "进度 \(StatsFormat.percent(progress))")
        } else {
            parts.append("进度未统计")
        }
        if let remaining = book.remainingSeconds {
            parts.append(StatsFormat.remaining(remaining))
        }
        parts.append(StatsFormat.relative(book.lastRead))
        return parts.joined(separator: "，")
    }
}

// MARK: - 书架进度

/// 已完成 / 在读 / 未开始。
///
/// 「在读」= 开始过但没读完，和「已读完」互斥；三者相加等于书库总数。
/// 分母用书库总数而不是「开始过的书」：这张卡回答的是「我的书架构成」，
/// 读完率另在书籍卡里用「已读完 / 开始过」口径，两者不混。
struct LibraryProgressCard: View {

    let overview: ReadingStatsOverview
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    private var reading: Int {
        max(0, overview.startedBooks - overview.finishedBooks)
    }

    private var unread: Int {
        max(0, overview.libraryCount - overview.startedBooks)
    }

    var body: some View {
        StatsCard(title: "书架进度", subtitle: "共 \(overview.libraryCount) 本") {
            if overview.libraryCount == 0 {
                Text("书库里还没有书")
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.secondaryText)
            } else if typeSize.isAccessibilitySize {
                rows
            } else {
                HStack(alignment: .center, spacing: 20) {
                    StatsRing(
                        finished: overview.finishedBooks,
                        reading: reading,
                        total: overview.libraryCount,
                        accent: accent
                    )

                    rows
                }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(
                label: "已读完",
                value: overview.finishedBooks,
                color: accent
            )
            row(
                label: "在读",
                value: reading,
                color: accent.opacity(0.55)
            )
            row(
                label: "未开始",
                value: unread,
                color: Color.primary.opacity(0.20)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text("\(value) 本")
                .font(.subheadline)
                .fontDesign(.rounded)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) 本")
    }
}
