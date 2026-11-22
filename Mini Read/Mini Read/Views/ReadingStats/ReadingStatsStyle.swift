//
//  ReadingStatsStyle.swift
//  TheNewVellium
//
//  统计页的视觉语言：颜色、数字排版与容器零件。
//
//  ## 为什么全部收在这里
//  统计页有九个区块。如果每个区块自己写圆角、字号、灰度，页面很快就会
//  变成「一堆长得差不多的卡片」，而不是「一页有层级的数据」。这里只暴露
//  语义化零件（卡片、指标、进度条、环、范围选择），区块层只负责组合。
//
//  ## 与 Apple Books 的关系
//  参考的是它的**信息层级**：一屏只留一个主数字，其余按卡片分组；
//  标签小而灰、数字大而圆；颜色只用来标记「同一件事」，不用来装饰。
//  没有照搬 Reading Goals 的环形目标——本项目没有「每日目标」这份数据，
//  先造一个目标再画进度，是在用精确的图形讲一个编出来的故事。
//

import Foundation
import SwiftUI
import UIKit

// MARK: - 数字格式

/// 纯函数，`nonisolated`：Swift Charts 的无障碍描述符可能被辅助功能
/// 在非主线程查询，格式化不能依赖主 actor。
nonisolated enum StatsFormat {

    /// "1 小时 12 分" / "48 分"
    static func duration(_ seconds: Int) -> String {
        let minutes = Int((Double(max(0, seconds)) / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) 分" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    /// 行尾的紧凑形式："还需 3 小时" / "还需 40 分"
    static func remaining(_ seconds: Int) -> String {
        let minutes = max(0, seconds / 60)
        guard minutes >= 60 else { return "还需 \(minutes) 分" }
        return "还需 \(minutes / 60) 小时"
    }

    /// 图表 Y 轴：数值大了必须收窄，否则 1000+ 会挤掉绘图区。
    static func axisMinutes(_ minutes: Int) -> String {
        guard minutes >= 1000 else { return "\(minutes)" }
        return String(format: "%.1fk", Double(minutes) / 1000)
    }

    static func percent(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "—" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    /// 涨跌一律「箭头 + 数字」，不靠颜色表达好坏。
    static func change(_ ratio: Double) -> String {
        let value = Int((abs(ratio) * 100).rounded())
        if value == 0 { return "持平" }
        return ratio >= 0 ? "↑\(value)%" : "↓\(value)%"
    }

    static func weekday(_ index: Int) -> String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        guard index >= 0, index < names.count else { return "" }
        return names[index]
    }

    /// 热力图左侧只放一个字，24 列才有空间。
    static func shortWeekday(_ index: Int) -> String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        guard index >= 0, index < names.count else { return "" }
        return names[index]
    }

    static func hour(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    static func day(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0) 月 \(components.day ?? 0) 日"
    }

    /// "2026 年 11 月"。
    ///
    /// 不用 `Date.FormatStyle`：它的语言跟随系统，而本 App 的界面文案全是
    /// 中文——系统语言是英文时会冒出 "Nov 2026"，一页里混两种语言。
    static func monthYear(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0) 年 \(components.month ?? 0) 月"
    }

    /// "2 小时前"。统计页里它回答的是「这本书是不是刚放下」。
    ///
    /// 同样手写而不用 `RelativeFormatStyle`：理由与 `monthYear` 相同，
    /// 而且这里只需要「刚刚 / 分钟 / 小时 / 天 / 周 / 个月 / 年」这几档。
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }

        let days = hours / 24
        if days < 7 { return "\(days) 天前" }
        if days < 30 { return "\(days / 7) 周前" }
        if days < 365 { return "\(days / 30) 个月前" }
        return "\(days / 365) 年前"
    }
}

// MARK: - 颜色

enum StatsPalette {

    /// 界面本来的强调色（`ReadingStats.swift` 里那个暖琥珀）。
    static let amber = Color(red: 0.784, green: 0.514, blue: 0.227)

    static let pageFill = Color(.systemGroupedBackground)
    static let cardFill = Color(.secondarySystemGroupedBackground)

    static let hairline = Color.primary.opacity(0.06)
    static let separator = Color.primary.opacity(0.10)
    static let track = Color.primary.opacity(0.07)

    /// 正文级次要信息。系统 `secondaryLabel` 在浅色下约 3.5:1，
    /// 小字号读起来偏虚；0.68 的黑/白在两种模式下都能过 4.5:1。
    static let secondaryText = Color.primary.opacity(0.68)

    /// 只给轴标签、页脚这类「有更好、没有也能懂」的信息。仍保持 4.5:1。
    static let tertiaryText = Color.primary.opacity(0.55)

    /// 主题色是近灰色时（默认 `#6B7280`，饱和度约 0.16），图表会退成
    /// 一排没有层次的灰条。这时候用暖琥珀：它本来就是这套界面的强调色，
    /// 不是另起一套。阈值取 0.20——刚好放过默认灰蓝，又不会误伤
    /// 用户主动挑的低饱和色（比如墨绿、砖红）。
    static func accent(hex: String) -> Color {
        let tint = Color(hex: hex) ?? amber

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        if UIColor(tint).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ), saturation < 0.20 {
            return amber
        }
        return tint
    }

    /// 小字号强调色。
    ///
    /// 主题色是用户用取色器挑的，可能是浅黄、浅粉——直接当文字色会掉到
    /// 2:1 上下。这里按 WCAG 对比度把颜色往背景的反侧推，直到 ≥ 5:1
    /// （留出彩色胶囊底色的余量）；色相不变，只改明度。
    static func readable(_ color: Color) -> Color {
        let base = UIColor(color)

        return Color(UIColor { traits in
            let resolved = base.resolvedColor(with: traits)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0

            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return resolved
            }

            let isDark = traits.userInterfaceStyle == .dark
            let background: (CGFloat, CGFloat, CGFloat) = isDark
                ? (0.11, 0.11, 0.118)
                : (1, 1, 1)
            let target: CGFloat = isDark ? 1 : 0

            var current = (red, green, blue)
            var steps = 0

            while contrastRatio(current, background) < 5, steps < 24 {
                current.0 += (target - current.0) * 0.08
                current.1 += (target - current.1) * 0.08
                current.2 += (target - current.2) * 0.08
                steps += 1
            }

            return UIColor(red: current.0, green: current.1, blue: current.2, alpha: 1)
        })
    }

    nonisolated private static func contrastRatio(
        _ foreground: (CGFloat, CGFloat, CGFloat),
        _ background: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        let first = relativeLuminance(foreground)
        let second = relativeLuminance(background)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    nonisolated private static func relativeLuminance(
        _ color: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.0)
            + 0.7152 * channel(color.1)
            + 0.0722 * channel(color.2)
    }
}

// MARK: - 卡片表面

extension View {

    /// 统计页唯一的卡片表面。
    func statsCardSurface(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(StatsPalette.cardFill)
                .overlay {
                    shape.strokeBorder(StatsPalette.hairline, lineWidth: 0.5)
                }
        }
    }
}

/// 标题在左、口径在右——「近 30 天」这类限定词必须跟数字在一起，
/// 否则用户会把不同窗口的数字放在一起比较。
struct StatsCard<Content: View>: View {

    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardSurface()
        .accessibilityElement(children: .contain)
    }

    /// 大字号下标题与口径并排会把两者都挤断，改成上下两行。
    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                titleText
                subtitleText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleText
                Spacer(minLength: 8)
                subtitleText
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(StatsPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - 指标

/// 一个小号指标：标签在上、数值在下。数值统一圆体 + 等宽数字，
/// 刷新时宽度不跳。
struct StatsMetric: View {

    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(StatsPalette.secondaryText)

            Text(value)
                .font(.title3)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 进度条

/// 细进度条。数值极小时至少留一个圆点，否则「读过一点」和「没读」看不出区别。
struct StatsBar: View {

    let fraction: Double
    let accent: Color
    var height: CGFloat = 4

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StatsPalette.track)

                if clamped > 0 {
                    Capsule()
                        .fill(accent)
                        .frame(width: max(height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 封面

/// 统计页的封面缩略图。
///
/// `CoverThumbnailView` 在「有 URL 但读不到图」时什么都不画（书库那边由
/// 网格占位兜底），统计页的卡片没有兜底，就会留一块说不清的空洞。
/// 这里补一层纸色底 + 书本图标，图加载出来后原样盖在上面。
struct StatsCover: View {

    let url: URL?
    let size: CGSize
    var cornerRadius: CGFloat = 5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            Image(systemName: "book.closed")
                .font(.system(size: min(size.width, size.height) * 0.30, weight: .light))
                .foregroundStyle(StatsPalette.tertiaryText)

            CoverThumbnailView(url: url, size: size, cornerRadius: cornerRadius)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - 环形进度

/// 书架构成环：已读完 / 在读 / 未开始。
///
/// 只做「看一眼比例」的图形，具体数字由右侧三行承担——环心的百分比
/// 在大字号下放不下，因此可访问性字号下整个环退场，只留列表。
struct StatsRing: View {

    let finished: Int
    let reading: Int
    let total: Int
    let accent: Color

    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 78

    private var size: CGFloat { min(baseSize, 104) }
    private var finishedShare: Double {
        total > 0 ? Double(finished) / Double(total) : 0
    }
    private var readingShare: Double {
        total > 0 ? Double(reading) / Double(total) : 0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(StatsPalette.track, lineWidth: 9)

            segment(from: 0, share: finishedShare, color: accent)
            segment(
                from: finishedShare,
                share: readingShare,
                color: accent.opacity(0.55)
            )

            center
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var center: some View {
        VStack(spacing: 0) {
            Text(total > 0 ? StatsFormat.percent(finishedShare) : "—")
                .font(.headline)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text("已读完")
                .font(.caption2)
                .foregroundStyle(StatsPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: size * 0.62)
    }

    private func segment(from start: Double, share: Double, color: Color) -> some View {
        // 段与段之间留一道发丝缝：三种颜色叠在一起时，缝比色差更清楚。
        let gap = share > 0.02 ? 0.006 : 0
        let lower = min(max(start + gap, 0), 1)
        let upper = min(max(start + share - gap, lower), 1)

        return Circle()
            .trim(from: lower, to: upper)
            .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

// MARK: - 范围选择

/// 统计范围。大字号下四段会被截断成「7…」，换成菜单。
struct StatsRangePicker: View {

    @Binding var range: ReadingStatsRange
    let accent: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                menu
            } else {
                segmented
            }
        }
        .onChange(of: range) { _, _ in
            triggerHaptic(.light)
        }
    }

    private var segmented: some View {
        Picker("统计范围", selection: $range) {
            ForEach(ReadingStatsRange.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .tint(accent)
        .accessibilityLabel("统计范围")
    }

    private var menu: some View {
        Menu {
            Picker("统计范围", selection: $range) {
                ForEach(ReadingStatsRange.allCases) { item in
                    Text(item.subtitle).tag(item)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.footnote)
                    .accessibilityHidden(true)

                Text(range.subtitle)
                    .font(.subheadline)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .statsCardSurface(cornerRadius: 14)
        }
        .accessibilityLabel("统计范围")
        .accessibilityValue(range.subtitle)
    }
}

// MARK: - 分组标题

struct StatsSectionHeader: View {

    let title: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(StatsPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
