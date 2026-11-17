//
//  Haptics.swift
//  TheNewVellium
//
//  「设置 → 通用设置 → 触觉反馈」开关的**唯一**读取点，也是全 App 唯一的震动入口。
//

import UIKit
import SwiftData

/// 触觉反馈总闸。
///
/// ## 为什么必须收口到一处
/// 这个开关原先靠**每个调用点自己判断** `settings.hapticFeedback`。实测这种写法
/// 已经漂移：全 App 十处 `triggerHaptic` 里有四处（都在 ProfileSheet）从头到尾
/// 没判断过开关——用户把触觉反馈关掉，进出个人页、点统计卡、点头像照样震。
/// 而判断的那六处又各写各的（`guard`、`if`、局部 helper 三种写法）。
///
/// 收口到这里之后：开关只有一个读取点，新增调用点不可能漏；
/// 调用点也不必再写任何判断（写了就是重复，且迟早会和这里不一致）。
///
/// ## 闸门值的来源（三处，缺一不可）
/// 1. **启动播种** `seed(from:)`——App 冷启动时从库里读一次，保证第一帧起就正确；
/// 2. **设置变更同步** `sync(with:)`——开关翻转、恢复默认设置后各对齐一次；
/// 3. **触发时判断** `impact(_:)`——真正放电前最后一道。
///
/// 只有 (2) 是不够的：用户关掉开关后冷启动 App，闸门还停在默认值上，
/// 直接进个人页就会震——这正是"必须有一个启动播种点"的原因。
///
/// - Note: **仅主线程访问**。震动本来就是 UI 行为，全工程调用方都在主线程
///   （含 `DispatchQueue.main.asyncAfter`），因此不给 `isEnabled` 加锁——
///   与 `ChapterLRUCache` 采用同一条约定。
enum Haptics {

    /// 是否允许震动。
    ///
    /// 默认值与 `AppSettings.hapticFeedback` 的默认值一致，取 `true` 而非 `false`：
    /// 万一播种没跑到（容器尚未就绪等），行为退化成"照旧震"——与引入总闸之前
    /// 完全一样，不会出现"用户没关却一声不吭"的静默失效。
    /// 宁可多震一下，不可静默丢失反馈。
    private(set) static var isEnabled = true

    // MARK: - 闸门同步

    /// 从持久化设置播种。App 启动时调一次。
    ///
    /// 刻意**只读、不插入**：库里还没有设置行时（首次启动）直接保持默认值。
    /// 为了读一个布尔值就在启动路径上走 `appSettings()` 的自愈写入并不划算，
    /// 而"没有行"本身就等价于"全是默认值"，保持默认恰好就是正确行为。
    static func seed(from context: ModelContext) {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1
        guard let settings = try? context.fetch(descriptor).first else { return }
        isEnabled = settings.hapticFeedback
    }

    /// 把闸门对齐到当前设置。开关翻转、恢复默认设置之后各调一次。
    static func sync(with settings: AppSettings) {
        isEnabled = settings.hapticFeedback
    }

    // MARK: - 触发

    /// 触发一次震动。**全 App 的触觉反馈都必须走这里。**
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 触发一次**结果**反馈（成功 / 警告 / 失败）。
    ///
    /// 与 `impact` 分开，是因为它们回答的问题不同：
    /// `impact` 回答"发生了一次交互"（翻页、选中），
    /// `notification` 回答"某件耗时/不可逆的事有结果了"（导入一本书成功了没有）。
    /// 后者不该用 impact 顶替——系统为这三种语义调过不同的触感曲线。
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

/// 调用点用的短名字。
///
/// 保留这个自由函数而不是让调用点改写成 `Haptics.impact(...)`：它的名字在全工程
/// 已经用了十处，改成带命名空间的写法只是徒增 churn，并不增加任何表达力。
/// 真正的机制与状态都在 `Haptics` 里，这里只是转发。
///
/// - Important: 调用点**不要**再自己判断 `settings.hapticFeedback`——
///   判断在这里发生，且只在这里发生。
func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
    Haptics.impact(style)
}

/// `triggerNotificationHaptic` 是结果反馈的短名字，与 `triggerHaptic` 同一套路数。
///
/// 不重载 `triggerHaptic`：`triggerHaptic(.success)` 读起来像"触发一次成功"，
/// 而 `.success` 其实是另一个枚举的取值，容易让人以为在传风格参数。
/// 两个名字分开，读代码时不必回到定义处确认类型。
func triggerNotificationHaptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    Haptics.notification(type)
}
