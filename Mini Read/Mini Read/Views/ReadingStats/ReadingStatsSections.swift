//
//  ReadingStatsSections.swift
//  TheNewVellium
//
//  统计页的六个区块。每个区块只做一件事：
//  把 `ReadingStatsEngine` 算好的值画出来，不在这里做二次计算——
//  口径一旦分叉，「日均」和「合计」就会开始互相矛盾。
//

import Foundation
import SwiftUI
import Charts

// MARK: - 趋势

struct ReadingStatsTrendCard: View {

    let trend: ReadingStatsTrend
    let subtitle: String
    let accent: Color
    let reduceMotion: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        StatsCard(title: "阅读时长", subtitle: subtitle) {
            metrics

            if trend.totalSeconds < 60 {
                // 不到一分钟时画出来只会是一条空轴，不如直接说清楚。
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("这段时间的阅读还不足一分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                chart
            }
        }
    }

    private var metrics: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    StatsMetric(label: "合计", value: StatsFormat.duration(trend.totalSeconds))
                    StatsMetric(label: "\(trend.bucketNoun)均", value: StatsFormat.duration(trend.averageSeconds))
                    StatsMetric(label: "较上期", value: changeText)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    StatsMetric(label: "合计", value: StatsFormat.duration(trend.totalSeconds))
                    StatsMetric(label: "\(trend.bucketNoun)均", value: StatsFormat.duration(trend.averageSeconds))
                    StatsMetric(label: "较上期", value: changeText)
                }
            }
        }
    }

    /// 上期没有记录时是「—」：涨跌无从谈起，写 +100% 是编的。
    private var changeText: String {
        guard let ratio = trend.changeRatio else { return "—" }
        return StatsFormat.change(ratio)
    }

    private var chart: some View {
        let peak = max(trend.points.map(\.minutes).max() ?? 0, 1)
        let domain = 0...max(Int(Double(peak) * 1.18), 1)

        return Chart {
            ForEach(trend.points) { point in
                BarMark(
                    x: .value("时间", point.start, unit: trend.bucketComponent),
                    y: .value("分钟", point.minutes)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [accent.opacity(0.95), accent.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(3)
            }

            if trend.averageSeconds > 0 {
                RuleMark(y: .value("平均", trend.averageSeconds / 60))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.45))
            }
        }
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let minutes = value.as(Int.self) {
                        Text(StatsFormat.axisMinutes(minutes))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: tickDates) { value in
                AxisTick()
                    .foregroundStyle(Color.primary.opacity(0.10))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(labelByStart[date] ?? "")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: 168)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.35),
            value: trend.points.map(\.seconds)
        )
        .accessibilityChartDescriptor(TrendChartDescriptor(trend: trend))
        .accessibilityLabel("阅读时长趋势")
    }

    /// 30 根柱子放不下 30 个标签，均匀取 4–5 个刻度。
    private var tickDates: [Date] {
        let points = trend.points
        guard points.count > 1 else { return points.map(\.start) }

        let step = max(1, Int((Double(points.count) / 4).rounded()))
        var dates: [Date] = []
        var index = 0
        while index < points.count {
            dates.append(points[index].start)
            index += step
        }
        return dates
    }

    private var labelByStart: [Date: String] {
        Dictionary(
            trend.points.map { ($0.start, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// VoiceOver 读的是「本周日均 32 分钟，比上期增加 18%」这样的摘要，
/// 而不是 30 个坐标点。图表可访问性不是给每根柱子加个标签就完了。
nonisolated struct TrendChartDescriptor: AXChartDescriptorRepresentable {

    let trend: ReadingStatsTrend

    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "时间",
            categoryOrder: trend.points.map(\.accessibleLabel)
        )

        let peak = max(trend.points.map(\.minutes).max() ?? 0, 1)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "分钟",
            range: 0...Double(peak),
            gridlinePositions: []
        ) { value in
            "\(Int(value.rounded())) 分钟"
        }

        let series = AXDataSeriesDescriptor(
            name: "阅读时长",
            isContinuous: false,
            dataPoints: trend.points.map {
                AXDataPoint(x: $0.accessibleLabel, y: Double($0.minutes))
            }
        )

        var summary = "共 \(trend.points.count) 个\(trend.bucketNoun)，合计 \(StatsFormat.duration(trend.totalSeconds))，平均每\(trend.bucketNoun) \(StatsFormat.duration(trend.averageSeconds))"
        if let ratio = trend.changeRatio {
            summary += "，较上期\(ratio >= 0 ? "增加" : "减少") \(Int((abs(ratio) * 100).rounded()))%"
        }
        if let best = trend.best, best.seconds > 0 {
            summary += "。最多的是\(best.accessibleLabel)，\(StatsFormat.duration(best.seconds))"
        }

        return AXChartDescriptor(
            title: "阅读时长趋势",
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

// MARK: - 时段

struct ReadingStatsRhythmCard: View {

    let rhythm: ReadingStatsRhythm
    let subtitle: String
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        StatsCard(title: "阅读时段", subtitle: subtitle) {
            if typeSize.isAccessibilitySize {
                // 大字号下 24 列会被压成一条线，格子失去意义——降级成列表，
                // 而不是把格子挤小。
                slotList
            } else {
                heatmap
                legend
            }

            footer
        }
    }

    private var heatmap: some View {
        // 30 分钟作为满格参照：几十秒的记录不该把整张热力图点亮。
        let peak = max(rhythm.grid.flatMap { $0 }.max() ?? 0, 30 * 60)

        return VStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 6) {
                    Text(shortWeekday(weekday))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, alignment: .leading)

                    HStack(spacing: 2) {
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(cellColor(rhythm.grid[weekday][hour], peak: peak))
                                .frame(maxWidth: .infinity)
                                .frame(height: 11)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatsFormat.weekday(weekday))
                .accessibilityValue(rowSummary(weekday))
            }

            HStack(spacing: 6) {
                Color.clear
                    .frame(width: 14, height: 1)

                HStack(spacing: 0) {
                    Text("0")
                    Spacer(minLength: 0)
                    Text("6")
                    Spacer(minLength: 0)
                    Text("12")
                    Spacer(minLength: 0)
                    Text("18")
                    Spacer(minLength: 0)
                    Text("24")
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            }
            .padding(.top, 1)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent.opacity(legendOpacity(level)))
                    .frame(width: 10, height: 10)
            }

            Text("多")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var slotList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("阅读最集中的时段")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if rhythm.peakSlots.isEmpty {
                Text("本期还没有阅读记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rhythm.peakSlots) { slot in
                    HStack(spacing: 8) {
                        Text("\(StatsFormat.weekday(slot.weekday)) \(StatsFormat.hour(slot.hour))")
                            .font(.caption)
                        Spacer(minLength: 8)
                        Text(StatsFormat.duration(slot.seconds))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let profile = rhythm.profile {
                Text("\(profile.label) · \(StatsFormat.percent(profile.share))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(accent.opacity(0.12)))
            }

            if let peak = rhythm.peak {
                Text("最常在 \(StatsFormat.weekday(peak.weekday)) \(StatsFormat.hour(peak.hour))，累计 \(StatsFormat.duration(peak.seconds))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本期还没有阅读记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func shortWeekday(_ index: Int) -> String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        guard index >= 0, index < names.count else { return "" }
        return names[index]
    }

    private func cellColor(_ seconds: Int, peak: Int) -> Color {
        guard seconds > 0 else { return Color.primary.opacity(0.05) }
        let ratio = Double(seconds) / Double(peak)
        // 开方压缩：低值时段也要看得见，否则热力图只剩几个孤零零的深色格子。
        return accent.opacity(0.20 + 0.75 * pow(ratio, 0.55))
    }

    private func legendOpacity(_ level: Int) -> Double {
        [0.08, 0.25, 0.45, 0.65, 0.9][min(max(level, 0), 4)]
    }

    private func rowSummary(_ weekday: Int) -> String {
        let row = rhythm.grid[weekday]
        guard let peakHour = row.indices.max(by: { row[$0] < row[$1] }), row[peakHour] > 0 else {
            return "没有阅读"
        }
        let total = row.reduce(0, +)
        return "\(peakHour) 点读得最多，全天合计 \(StatsFormat.duration(total))"
    }
}

// MARK: - 单次时长

struct ReadingStatsSessionCard: View {

    let profile: ReadingStatsSessionProfile
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        StatsCard(title: "单次阅读", subtitle: subtitle) {
            if profile.count == 0 {
                Text("本期还没有完整的阅读记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profile.buckets) { bucket in
                        row(bucket)
                    }

                    Text("本期共 \(profile.count) 次阅读")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var subtitle: String {
        guard profile.count > 0 else { return "本期没有记录" }
        return "平均 \(StatsFormat.duration(profile.averageSeconds)) · 最长 \(StatsFormat.duration(profile.longestSeconds))"
    }

    @ViewBuilder
    private func row(_ bucket: ReadingStatsSessionBucket) -> some View {
        let peak = max(profile.buckets.map(\.count).max() ?? 0, 1)
        let fraction = Double(bucket.count) / Double(peak)

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(bucket.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(bucket.count) 次")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                StatsBar(fraction: fraction, accent: accent, height: 8)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                Text(bucket.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)

                StatsBar(fraction: fraction, accent: accent, height: 8)

                Text("\(bucket.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(bucket.label)，\(bucket.count) 次")
        }
    }
}

// MARK: - 书籍

struct ReadingStatsBooksCard: View {

    let books: [ReadingStatsBookSlice]
    let subtitle: String
    let accent: Color
    let overview: ReadingStatsOverview
    let completionRate: Double?

    @Environment(\.dynamicTypeSize) private var typeSize

    private var visibleBooks: [ReadingStatsBookSlice] {
        Array(books.prefix(6))
    }

    var body: some View {
        StatsCard(title: "书籍", subtitle: "\(subtitle) · \(books.count) 本") {
            if books.isEmpty {
                Text("这段时间还没有读过的书")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(visibleBooks) { book in
                        row(book)
                    }

                    if books.count > visibleBooks.count {
                        Text("仅显示本期阅读时长最长的 \(visibleBooks.count) 本")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Divider()
                        .overlay(Color.primary.opacity(0.06))

                    Text(footerText)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 读完率的分母是「开始过的书」，不是「书库里的书」——
    /// 把刚导入还没翻开的书算进分母，等于替用户判了不及格。
    private var footerText: String {
        guard let rate = completionRate else {
            return "书库 \(overview.libraryCount) 本 · 已读完 \(overview.finishedBooks) 本"
        }
        return "书库 \(overview.libraryCount) 本 · 读完率 \(StatsFormat.percent(rate))（\(overview.finishedBooks) / \(overview.startedBooks) 本）"
    }

    private func row(_ book: ReadingStatsBookSlice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CoverThumbnailView(
                url: book.coverURL,
                size: CGSize(width: 38, height: 56),
                cornerRadius: 5
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if let remaining = book.remainingSeconds {
                        Text(StatsFormat.remaining(remaining))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) {
                        progressLine(book)
                        Text("本期 \(StatsFormat.duration(book.seconds)) · \(book.sessionCount) 次")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        progressLine(book)

                        Spacer(minLength: 8)

                        Text("本期 \(StatsFormat.duration(book.seconds))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(book))
    }

    @ViewBuilder
    private func progressLine(_ book: ReadingStatsBookSlice) -> some View {
        if let progress = book.progress {
            HStack(spacing: 6) {
                StatsBar(fraction: progress, accent: accent, height: 3)
                    .frame(maxWidth: 120)
                Text(StatsFormat.percent(progress))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if book.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accent)
                }
            }
        } else {
            Text("进度未统计")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func accessibilityLabel(_ book: ReadingStatsBookSlice) -> String {
        var parts = [book.title]
        if !book.author.isEmpty { parts.append(book.author) }
        parts.append("本期 \(StatsFormat.duration(book.seconds))")
        if let progress = book.progress {
            parts.append(book.isFinished ? "已读完" : "进度 \(StatsFormat.percent(progress))")
        }
        if let remaining = book.remainingSeconds {
            parts.append(StatsFormat.remaining(remaining))
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 作者

struct ReadingStatsAuthorsCard: View {

    let authors: [ReadingStatsAuthorSlice]
    let subtitle: String
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    private var totalSeconds: Int {
        max(authors.reduce(0) { $0 + $1.seconds }, 1)
    }

    var body: some View {
        StatsCard(title: "作者", subtitle: subtitle) {
            if authors.isEmpty {
                Text("本期还没有可以归类的作者")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(authors) { author in
                        row(author)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ author: ReadingStatsAuthorSlice) -> some View {
        let fraction = Double(author.seconds) / Double(totalSeconds)

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(author.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(StatsFormat.duration(author.seconds))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                StatsBar(fraction: fraction, accent: accent, height: 5)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                Text(author.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 110, alignment: .leading)

                StatsBar(fraction: fraction, accent: accent, height: 5)

                Text(StatsFormat.duration(author.seconds))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(author.name)，\(StatsFormat.duration(author.seconds))，\(author.bookCount) 本")
        }
    }
}

// MARK: - 洞察

struct ReadingStatsInsightsCard: View {

    let insights: ReadingStatsInsights
    let nightShare: Double
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: count)
    }

    var body: some View {
        StatsCard(title: "洞察", subtitle: "本期") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                tile(
                    title: "章节节奏",
                    value: insights.chapterPace.map { String(format: "%.1f 章/时", $0) } ?? "—",
                    detail: "本期读完 \(insights.chaptersInRange) 章"
                )

                tile(
                    title: "深夜阅读",
                    value: StatsFormat.percent(nightShare),
                    detail: "23:00–05:00 的占比"
                )

                tile(
                    title: "书签",
                    value: "\(insights.bookmarksInRange) 个",
                    detail: bookmarkDetail
                )

                tile(
                    title: "有阅读的天数",
                    value: StatsFormat.percent(insights.activeDayShare),
                    detail: "\(insights.activeDaysInRange) / \(insights.elapsedDays) 天"
                )
            }
        }
    }

    /// 密度低于 0.1 时写成「每小时 0.0 个」等于没写，直接给总数。
    private var bookmarkDetail: String {
        if let density = insights.bookmarkDensity, density >= 0.1 {
            return "每小时 \(String(format: "%.1f", density)) 个 · 共 \(insights.bookmarksTotal) 个"
        }
        return "共 \(insights.bookmarksTotal) 个书签"
    }

    private func tile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 20, weight: .regular, design: .serif))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
