//
//  ReadingStatsStyle.swift
//  TheNewVellium
//
//  统计页的排版与容器。抽出来只为一件事：同一个数字在页面任何位置
//  都长同一个样子——衬线、等宽数字、同一档字号。散落在各 section 里
//  手写 `.font(...)` 迟早会漂。
//

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
        "\(Int((ratio * 100).rounded()))%"
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

    static func hour(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month().day())
    }
}

// MARK: - 颜色

enum StatsPalette {

    /// 界面本来的强调色（`ReadingStats.swift` 里那个暖琥珀）。
    static let amber = Color(red: 0.784, green: 0.514, blue: 0.227)

    /// 主题色是近灰色时（默认 `#6B7280`），图表会退成一排没有层次的灰条。
    /// 这时候用暖琥珀：它本来就是这套界面的强调色，不是另起一套。
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
        ), saturation < 0.12 {
            return amber
        }
        return tint
    }
}

// MARK: - 卡片

/// 统计页唯一的容器。标题在左、口径在右——「近 30 天」这类限定词
/// 必须跟数字在一起，否则用户会把不同窗口的数字放在一起比较。
struct StatsCard<Content: View>: View {

    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    /// 大字号下标题与口径并排会把两者都挤断，改成上下两行。
    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
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
                    .fill(Color.primary.opacity(0.08))

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

// MARK: - 指标

/// 一个小号指标：标签在上、数值在下。数值统一衬线 + 等宽数字，
/// 刷新时宽度不跳。
struct StatsMetric: View {

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
