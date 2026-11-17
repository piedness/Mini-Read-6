//
//  PageTurnStyle.swift
//  TheNewVellium
//
//  翻页样式的单一真相源：持久化值 → 生效样式的解析，以及一次性的存量迁移。
//
//  为什么需要「偏好」与「生效值」两套：
//  偏好是用户选的，生效值是这一刻真正能用的。两者只在平台硬约束下分叉——
//  iPad 双页（`.scroll` 下双页会消失）与系统「降低动态效果」（卷曲是三维大幅
//  位移）。其余情况一律跟随用户。
//

import UIKit
import SwiftData

// MARK: - 样式

/// 阅读器翻页样式。
///
/// `rawValue` 与 `AppSettings.pageTransitionStyle` 的持久化值一一对应；
/// 设置页的 Picker tag 也直接取自这里，避免"枚举改了、tag 没改"这种静默错位
/// （那种错位的表现是：用户点了没反应，且没有任何日志）。
enum PageTurnStyle: String, CaseIterable, Identifiable, Sendable {

    /// 仿真卷曲 → `UIPageViewController.TransitionStyle.pageCurl`
    case curl

    /// 连续滑动 → `.scroll`（跟手拖动 + 分页吸附）
    ///
    /// 注意它与 Apple Books 的「滑动」不是一回事：后者是整页滑入的离散动画，
    /// 这里是内容跟手移动、松手后吸附到页边界。`UIPageViewController` 没有
    /// 提供离散滑动的公开转场，要做只能自研容器——不在本次改动范围内。
    case slide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .curl:  return "仿真翻页"
        case .slide: return "连续滑动"
        }
    }

    var systemImage: String {
        switch self {
        case .curl:  return "book.pages"
        case .slide: return "arrow.left.and.right"
        }
    }

    var transitionStyle: UIPageViewController.TransitionStyle {
        switch self {
        case .curl:  return .pageCurl
        case .slide: return .scroll
        }
    }
}

// MARK: - 解析

/// 把「用户偏好」翻译成「这一刻真正该用的样式」。
///
/// 只剩两条降级，都是平台硬约束，不是设计口味：
///
/// 1. **iPad 双页 → 固定卷曲**。`isDoubleSided` 与 `spineLocation` 只在
///    `.pageCurl` 下生效；换成 `.scroll` 后 UIKit 会忽略它们，整本书从双页
///    退化成单页。双页是 iPad 上最有价值的一处差异，不能为了翻页样式丢掉。
/// 2. **降低动态效果 → 连续滑动**。卷曲是三维大幅位移（整页绕轴翻转 + 阴影
///    扫过），对前庭敏感用户不友好；滑动只有水平位移，观感平缓得多。
///
/// 其余一律跟随用户偏好。
///
/// ## 深色纸面为什么不需要降级
/// 卷曲的背面归 App 自己管：iPhone 的 `.min` 书脊 + `isDoubleSided = true`
/// 就是「单页 + 正反面」模型，背面是一个真正的 view controller
/// （`PageBackViewController`），纸色/纹理/透印全部跟随阅读设置；
/// iPad 的 `.mid` 里翻过去那一张的背面本来就是另一页真实内容。
/// 既然两面都跟着纸面走，就没有为它偷换转场的理由——读者选了
/// 仿真翻页，就按他选的来。
enum PageTurnStyleResolver {

    /// 解析生效样式。
    ///
    /// - Parameters:
    ///   - preference: 持久化的偏好值。无法识别的值（旧版本遗留、外部导入的
    ///     配置文件）一律按卷曲处理——那是本字段接通之前全 App 的实际表现，
    ///     回退到它不会让读者的观感发生意外跳变。
    ///   - isRegular: 是否 iPad 双页（regular 宽度）。
    ///   - reduceMotion: 默认取系统开关；显式传入便于在调用点/测试里覆盖该分支。
    static func resolve(
        preference: String,
        isRegular: Bool,
        reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled
    ) -> PageTurnStyle {
        if isRegular { return .curl }
        if reduceMotion { return .slide }
        return PageTurnStyle(rawValue: preference) ?? .curl
    }
}

// MARK: - 存量迁移

/// 把「从未生效过」的历史偏好一次性归位。
///
/// `pageTransitionStyle` 从加入 schema 起就没被阅读器读过（`setupPageVC` 里
/// 硬编码 `.pageCurl`）。也就是说存量的 `"slide"` 只是 schema 默认值，
/// 不承载任何用户意图——用户点了 Picker 也不会有任何可见变化。
///
/// 一旦接通这个字段，若不做迁移，**所有老用户升级后翻页方式会从卷曲变成
/// 滑动**——这是对核心阅读交互的静默改动。所以这里在首次启动时统一写成
/// `curl`，保持他们一直看到的行为；此后用户再选什么就是真实意图了。
///
/// 全新安装不会走到写入分支（启动时库里还没有设置行），设置行之后按 schema
/// 默认值 `"slide"` 创建——新用户拿到的是更稳的默认值，而不是历史包袱。
enum PageTurnStyleMigration {

    private static let didMigrateKey = "vellium.pageTurnStyle.didMigrateToWired"

    /// App 启动时调一次。与 `Haptics.seed(from:)` 同构：只读/只写一次，幂等。
    static func runIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didMigrateKey) else { return }

        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1

        guard let settings = try? context.fetch(descriptor).first else {
            // 全新安装：没有设置行可迁移，直接记账，避免每次启动重试。
            defaults.set(true, forKey: didMigrateKey)
            return
        }

        if settings.pageTransitionStyle != PageTurnStyle.curl.rawValue {
            settings.pageTransitionStyle = PageTurnStyle.curl.rawValue
            try? context.save()
        }

        defaults.set(true, forKey: didMigrateKey)
    }
}
