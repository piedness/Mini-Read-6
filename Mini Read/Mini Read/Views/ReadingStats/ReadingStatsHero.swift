//
//  ReadingStatsHero.swift
//  TheNewVellium
//
//  统计页首屏。只回答「今天读了吗、连着读了几天、最近是不是稳定」。
//
//  刻意不放累计小时数：那是个只会变大、不会给下一步动作的数字。
//  累计放在标题下面一行小字里，够用就好。
//

import SwiftUI

struct ReadingStatsHero: View {

    /// `nil` = 数据还没算好。此时数字显示「—」，布局不跳。
    let overview: ReadingStatsOverview?
    let accent: Color

    /// 首屏数字跟着 Dynamic Type 一起长，而不是钉死在 46pt。
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text("今日阅读")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Spacer(minLength: 8)

                streakBadge
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(todayValue)
                    .font(.system(size: numberSize, weight: .light, design: .serif))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)

                Text(todayUnit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("今日阅读")
            .accessibilityValue("\(todayValue) \(todayUnit)")

            Text(caption)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            sparkline
        }
        .padding(20)
        .background(background)
    }

    // MARK: - 背景

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return shape
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [accent.opacity(0.20), accent.opacity(0.01)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(
                shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }

    // MARK: - 数字

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

    private var caption: String {
        guard let overview else { return " " }
        guard overview.totalSeconds > 0 else {
            return " "
        }
        return "本周 \(StatsFormat.duration(overview.weekSeconds)) · 累计 \(StatsFormat.duration(overview.totalSeconds))"
    }

    // MARK: - 连续天数

    @ViewBuilder
    private var streakBadge: some View {
        if let streak = overview?.currentStreak, streak > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(streak) 天")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(accent.opacity(0.14)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("连续阅读 \(streak) 天")
        }
    }

    // MARK: - 近 14 天

    private var sparkline: some View {
        let days = overview?.recentDays ?? []
        // 用 15 分钟作为刻度下限：只有几十秒记录时，按峰值归一化会把
        // 那一条画成满格，看起来像「读了一整天」。
        let scale = max(days.map(\.seconds).max() ?? 0, 15 * 60)

        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fillColor(for: day))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(for: day, scale: scale))
                }
            }
            .frame(height: 36, alignment: .bottom)

            HStack(spacing: 8) {
                Text("近 14 天")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                if !days.isEmpty {
                    Text("日均 \(StatsFormat.duration(average(days)))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 14 天阅读趋势")
        .accessibilityValue(summary(days))
    }

    private func fillColor(for day: ReadingStatsDay) -> Color {
        guard day.seconds > 0 else { return Color.primary.opacity(0.08) }
        return day.isToday ? accent : accent.opacity(0.32)
    }

    private func barHeight(for day: ReadingStatsDay, scale: Int) -> CGFloat {
        guard day.seconds > 0 else { return 3 }
        let ratio = CGFloat(day.seconds) / CGFloat(max(scale, 1))
        return max(4, 36 * ratio)
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
}

// MARK: - 当前在读

/// 「还想继续读」的唯一入口：一本书、一个进度、一个还要多久。
///
/// 刻意不做成可点击——跳转阅读器要走书架的封面缩放转场，
/// 这里半途接一个没有转场的入口，会把「从封面进入阅读」的观感打散。
struct CurrentBookCard: View {

    let book: ReadingStatsCurrentBook
    let accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CoverThumbnailView(
                url: book.coverURL,
                size: CGSize(width: 42, height: 60),
                cornerRadius: 5
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(book.isFinished ? "最近阅读" : "继续阅读")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let progress = book.progress {
                    HStack(spacing: 8) {
                        StatsBar(fraction: progress, accent: accent, height: 3)
                        Text(StatsFormat.percent(progress))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("进度未统计")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if let remaining = book.remainingSeconds {
                Text(StatsFormat.remaining(remaining))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 76, alignment: .trailing)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [book.isFinished ? "最近阅读" : "继续阅读", book.title]
        if !book.author.isEmpty { parts.append(book.author) }
        if let progress = book.progress {
            parts.append("进度 \(StatsFormat.percent(progress))")
        }
        if let remaining = book.remainingSeconds {
            parts.append(StatsFormat.remaining(remaining))
        }
        return parts.joined(separator: "，")
    }
}
