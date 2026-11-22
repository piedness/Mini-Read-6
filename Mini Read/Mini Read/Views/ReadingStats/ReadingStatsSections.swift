//
//  ReadingStatsSections.swift
//  TheNewVellium
//
//  统计页的六个区块。每个区块只做一件事：
//  把 `ReadingStatsEngine` 算好的值画出来，不在这里做二次计算——
//  口径一旦分叉，「日均」和「合计」就会开始互相矛盾。
//
//  版式统一走 `ReadingStatsStyle` 里的零件；这里只决定「放几个、怎么排」。
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
    /// iPad 宽版把趋势图铺满整行，170pt 会显得太扁。
    var chartHeight: CGFloat = 170

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        StatsCard(title: "阅读趋势", subtitle: subtitle) {
            metrics

            if trend.totalSeconds < 60 {
                // 不到一分钟时画出来只会是一条空轴，不如直接说清楚。
                emptyChart
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
                    StatsMetric(
                        label: "\(trend.bucketNoun)均",
                        value: StatsFormat.duration(trend.averageSeconds)
                    )
                    StatsMetric(label: "较上期", value: changeText, tint: changeTint)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    StatsMetric(label: "合计", value: StatsFormat.duration(trend.totalSeconds))
                    StatsMetric(
                        label: "\(trend.bucketNoun)均",
                        value: StatsFormat.duration(trend.averageSeconds)
                    )
                    StatsMetric(label: "较上期", value: changeText, tint: changeTint)
                }
            }
        }
    }

    /// 上期没有记录时是「—」：涨跌无从谈起，写 +100% 是编的。
    private var changeText: String {
        guard let ratio = trend.changeRatio else { return "—" }
        return StatsFormat.change(ratio)
    }

    private var changeTint: Color {
        guard let ratio = trend.changeRatio, ratio > 0 else {
            return StatsPalette.secondaryText
        }
        return StatsPalette.readable(accent)
    }

    private var emptyChart: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar")
                .font(.title3)
                .foregroundStyle(StatsPalette.tertiaryText)
                .accessibilityHidden(true)

            Text("这段时间的阅读还不足一分钟")
                .font(.footnote)
                .foregroundStyle(StatsPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private var chart: some View {
        let peak = max(trend.points.map(\.minutes).max() ?? 0, 1)
        let domain = 0...max(Int(Double(peak) * 1.18), 1)

        let base = Chart {
            ForEach(trend.points) { point in
                BarMark(
                    x: .value("时间", point.start, unit: trend.bucketComponent),
                    y: .value("分钟", point.minutes)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(3)
            }

            if trend.averageSeconds > 0 {
                RuleMark(y: .value("平均", Double(trend.averageSeconds) / 60))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(StatsPalette.tertiaryText.opacity(0.6))
            }
        }
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .frame(height: chartHeight)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.35),
            value: trend.points.map(\.seconds)
        )
        .accessibilityChartDescriptor(TrendChartDescriptor(trend: trend))
        .accessibilityLabel("阅读时长趋势")

        return Group {
            if typeSize.isAccessibilitySize {
                // 轴标签跟着字号长到 28pt 后，4 个日期会挤成「10/24/11 1/9」。
                // 大字号下把轴交给文字摘要，图只保留形状；VoiceOver 另有
                // `TrendChartDescriptor` 逐点描述。
                VStack(alignment: .leading, spacing: 8) {
                    base
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)

                    peakNote
                }
            } else {
                base
                    .chartYAxis {
                        // 只要两个刻度、不要网格线：这张图回答的是「形状」，
                        // 具体数值由上方三个指标承担。
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                            AxisValueLabel {
                                if let minutes = value.as(Int.self) {
                                    Text(StatsFormat.axisMinutes(minutes))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(StatsPalette.tertiaryText)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: tickDates) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(labelByStart[date] ?? "")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(StatsPalette.tertiaryText)
                                }
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var peakNote: some View {
        if let best = trend.best, best.seconds > 0 {
            Text("最多的一天是 \(best.accessibleLabel)，\(StatsFormat.duration(best.seconds))")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(StatsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    @Environment(\.colorScheme) private var colorScheme

    private var accentText: Color { StatsPalette.readable(accent) }

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

        return VStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 6) {
                    Text(StatsFormat.shortWeekday(weekday))
                        .font(.caption2)
                        .foregroundStyle(StatsPalette.tertiaryText)
                        .frame(width: 16, alignment: .leading)

                    HStack(spacing: 2) {
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(cellColor(rhythm.grid[weekday][hour], peak: peak))
                                .frame(maxWidth: .infinity)
                                .frame(height: 12)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatsFormat.weekday(weekday))
                .accessibilityValue(rowSummary(weekday))
            }

            HStack(spacing: 6) {
                Color.clear
                    .frame(width: 16, height: 1)

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
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(StatsPalette.tertiaryText)
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(.caption2)
                .foregroundStyle(StatsPalette.tertiaryText)

            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent.opacity(legendOpacity(level)))
                    .frame(width: 10, height: 10)
            }

            Text("多")
                .font(.caption2)
                .foregroundStyle(StatsPalette.tertiaryText)

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var slotList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("阅读最集中的时段")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(StatsPalette.secondaryText)

            if rhythm.peakSlots.isEmpty {
                Text("本期还没有阅读记录")
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.tertiaryText)
            } else {
                ForEach(rhythm.peakSlots) { slot in
                    HStack(spacing: 8) {
                        Text("\(StatsFormat.weekday(slot.weekday)) \(StatsFormat.hour(slot.hour))")
                            .font(.footnote)

                        Spacer(minLength: 8)

                        Text(StatsFormat.duration(slot.seconds))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(StatsPalette.secondaryText)
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
                    .foregroundStyle(accentText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    )
            }

            if let peak = rhythm.peak {
                Text("最常在 \(StatsFormat.weekday(peak.weekday)) \(StatsFormat.hour(peak.hour))，累计 \(StatsFormat.duration(peak.seconds))")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(StatsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本期还没有阅读记录")
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.tertiaryText)
            }
        }
    }

    private func cellColor(_ seconds: Int, peak: Int) -> Color {
        guard seconds > 0 else { return Color.primary.opacity(0.05) }
        let ratio = Double(seconds) / Double(peak)
        // 开方压缩：低值时段也要看得见，否则热力图只剩几个孤零零的深色格子。
        return accent.opacity(0.20 + 0.72 * pow(ratio, 0.55))
    }

    private func legendOpacity(_ level: Int) -> Double {
        [0.10, 0.26, 0.44, 0.62, 0.86][min(max(level, 0), 4)]
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
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profile.buckets) { bucket in
                        row(bucket)
                    }

                    Text("本期共 \(profile.count) 次阅读")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(StatsPalette.tertiaryText)
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
                        .font(.footnote)
                        .foregroundStyle(StatsPalette.secondaryText)

                    Spacer(minLength: 8)

                    Text("\(bucket.count) 次")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(StatsPalette.secondaryText)
                }

                StatsBar(fraction: fraction, accent: accent, height: 7)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                Text(bucket.label)
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.secondaryText)
                    .frame(width: 78, alignment: .leading)

                StatsBar(fraction: fraction, accent: accent, height: 7)

                Text("\(bucket.count)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(StatsPalette.secondaryText)
                    .frame(width: 24, alignment: .trailing)
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
        Array(books.prefix(5))
    }

    var body: some View {
        StatsCard(title: "本期书籍", subtitle: "\(subtitle) · \(books.count) 本") {
            if books.isEmpty {
                Text("这段时间还没有读过的书")
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleBooks) { book in
                        if book.id != visibleBooks.first?.id {
                            separator
                        }
                        row(book)
                    }

                    if books.count > visibleBooks.count {
                        Text("仅显示本期阅读时长最长的 \(visibleBooks.count) 本")
                            .font(.caption)
                            .foregroundStyle(StatsPalette.tertiaryText)
                    }

                    separator

                    Text(footerText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(StatsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(StatsPalette.separator)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    /// 读完率的分母是「开始过的书」，不是「书库里的书」——
    /// 把刚导入还没翻开的书算进分母，等于替用户判了不及格。
    private var footerText: String {
        guard let rate = completionRate else {
            return "书库 \(overview.libraryCount) 本 · 已读完 \(overview.finishedBooks) 本"
        }
        return "书库 \(overview.libraryCount) 本 · 读完率 \(StatsFormat.percent(rate))（\(overview.finishedBooks) / \(overview.startedBooks) 本）"
    }

    @ViewBuilder
    private func row(_ book: ReadingStatsBookSlice) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    cover(book)

                    VStack(alignment: .leading, spacing: 4) {
                        title(book)
                        author(book)
                    }
                }

                progressLine(book)

                Text("本期 \(StatsFormat.duration(book.seconds)) · \(book.sessionCount) 次")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(StatsPalette.secondaryText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(book))
        } else {
            HStack(alignment: .top, spacing: 12) {
                cover(book)

                VStack(alignment: .leading, spacing: 4) {
                    title(book)
                    author(book)

                    HStack(spacing: 12) {
                        progressLine(book)

                        Text("本期 \(StatsFormat.duration(book.seconds))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(StatsPalette.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.top, 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(book))
        }
    }

    private func cover(_ book: ReadingStatsBookSlice) -> some View {
        StatsCover(
            url: book.coverURL,
            size: CGSize(width: 36, height: 52),
            cornerRadius: 5
        )
    }

    private func title(_ book: ReadingStatsBookSlice) -> some View {
        Text(book.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .layoutPriority(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func author(_ book: ReadingStatsBookSlice) -> some View {
        Text(book.author.isEmpty ? "未知作者" : book.author)
            .font(.caption)
            .foregroundStyle(StatsPalette.secondaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    private func progressLine(_ book: ReadingStatsBookSlice) -> some View {
        if let progress = book.progress {
            HStack(spacing: 6) {
                // 进度条吃掉剩余宽度：iPad 宽列里固定 110pt 会显得很短，
                // 也会让「本期时长」孤零零地飘在右边。
                StatsBar(fraction: progress, accent: accent, height: 3)
                    .frame(maxWidth: .infinity)

                Text(StatsFormat.percent(progress))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(StatsPalette.secondaryText)

                if book.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(StatsPalette.readable(accent))
                        .accessibilityHidden(true)
                }
            }
        } else {
            Text("进度未统计")
                .font(.caption)
                .foregroundStyle(StatsPalette.tertiaryText)
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

    private var visibleAuthors: [ReadingStatsAuthorSlice] {
        Array(authors.prefix(3))
    }

    private var totalSeconds: Int {
        max(visibleAuthors.reduce(0) { $0 + $1.seconds }, 1)
    }

    var body: some View {
        StatsCard(title: "常读作者", subtitle: subtitle) {
            if visibleAuthors.isEmpty {
                Text("本期还没有可以归类的作者")
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleAuthors) { author in
                        row(author)
                    }
                }
            }
        }
    }

    private func row(_ author: ReadingStatsAuthorSlice) -> some View {
        let fraction = Double(author.seconds) / Double(totalSeconds)

        return VStack(alignment: .leading, spacing: 6) {
            // 名字单独占一行：固定列宽会把「[日]东野圭吾,张舟(译)」截成
            // 「[日]东野圭吾,…」，而作者名恰恰是这张卡里唯一需要看清的字。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(author.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                Text(StatsFormat.duration(author.seconds))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(StatsPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            StatsBar(fraction: fraction, accent: accent, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(author.name)，\(StatsFormat.duration(author.seconds))，\(author.bookCount) 本")
    }
}

// MARK: - 洞察

struct ReadingStatsInsightsCard: View {

    let insights: ReadingStatsInsights
    let nightShare: Double
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    private var accentText: Color { StatsPalette.readable(accent) }

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
            count: count
        )
    }

    var body: some View {
        StatsCard(title: "阅读洞察", subtitle: "本期") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                tile(
                    icon: "book.pages",
                    title: "章节节奏",
                    value: insights.chapterPace.map { String(format: "%.1f 章/时", $0) } ?? "—",
                    detail: "本期读完 \(insights.chaptersInRange) 章"
                )

                tile(
                    icon: "moon.stars",
                    title: "深夜阅读",
                    value: StatsFormat.percent(nightShare),
                    detail: "23:00–05:00 的占比"
                )

                tile(
                    icon: "bookmark",
                    title: "书签",
                    value: "\(insights.bookmarksInRange) 个",
                    detail: bookmarkDetail
                )

                tile(
                    icon: "calendar",
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
            let pace = "每小时 \(String(format: "%.1f", density)) 个"
            // 数值本身已经写了「7 个」，这里再写一遍「共 7 个」是重复。
            return insights.bookmarksInRange == insights.bookmarksTotal
                ? pace
                : "\(pace) · 共 \(insights.bookmarksTotal) 个"
        }
        return "共 \(insights.bookmarksTotal) 个书签"
    }

    private func tile(icon: String, title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(accentText)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(StatsPalette.secondaryText)
            }

            Text(value)
                .font(.title3)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(detail)
                .font(.caption)
                .foregroundStyle(StatsPalette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
