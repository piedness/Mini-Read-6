//
//  TheNewVelliumApp.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/4/11.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct Mini_ReadApp: App {

    init() {
        // 导航栏字体是全局外观（`UINavigationBar.appearance()`），必须在启动时
        // 一次性定好。它原先写在 `SettingSplit.init()` 里——那等于「设置页被
        // 构造」的副作用：首页 / 书库的导航栏能否拿到衬线标题，取决于 TabView
        // 有没有提前把设置页的视图值建出来。现在这两个 tab 都走系统导航栏，
        // 依赖必须确定，所以挪到这里。
        Self.applySerifNavigationAppearance()

        // 启动时把用户导入的字体重新注册进当前进程（.process 作用域不跨进程保留），
        // 保证重启后正文 / 预览仍能按名字解析到这些字体。
        ImportedFontStore.registerAll()

        // 播种触觉反馈总闸。必须在这里做，不能只靠"设置变更时同步"：
        // 用户把开关关掉后冷启动 App，若闸门一直停在默认值上，
        // 第一帧起的所有震动都会照常发出——开关形同虚设。
        Haptics.seed(from: sharedModelContainer.mainContext)

        // 翻页样式字段此前从未被阅读器读取，存量值只是 schema 默认值。
        // 接通前先归位，避免老用户升级后翻页方式被静默改掉（见 PageTurnStyle.swift）。
        PageTurnStyleMigration.runIfNeeded(in: sharedModelContainer.mainContext)

        // 默认书单「my favorite」：长按书籍的「Add to My Favorite」直接写进它。
        // 菜单目标是写死的，目标不存在就等于那条菜单失效，所以启动时补齐。
        DefaultCollection.ensure(in: sharedModelContainer.mainContext)
    }

    /// 导航栏（inline + large）统一用衬线体，与正文的 Georgia 语汇一致。
    ///
    /// 只改字体与前景色，不配背景：背景留给系统的 scroll edge effect，
    /// 内容滚到栏下时才会有那层渐进模糊；自己塞一块材质会和它打架。
    private static func applySerifNavigationAppearance() {
        let appearance = UINavigationBarAppearance()

        // MARK: - inline title（小标题）
        let inlineBase = UIFont.preferredFont(forTextStyle: .body)
        let inlineDescriptor = (inlineBase.fontDescriptor.withDesign(.serif) ?? inlineBase.fontDescriptor)
            .withSymbolicTraits(.traitBold) ?? inlineBase.fontDescriptor
        appearance.titleTextAttributes = [
            .font: UIFont(descriptor: inlineDescriptor, size: 0),
            .foregroundColor: UIColor.label
        ]

        // MARK: - large title（大标题）
        let largeBase = UIFont.preferredFont(forTextStyle: .largeTitle)
        let largeDescriptor = (largeBase.fontDescriptor.withDesign(.serif) ?? largeBase.fontDescriptor)
            .withSymbolicTraits(.traitBold) ?? largeBase.fontDescriptor
        appearance.largeTitleTextAttributes = [
            .font: UIFont(descriptor: largeDescriptor, size: 0),
            .foregroundColor: UIColor.label
        ]

        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            bookItem.self,
            ReadingProgressRecord.self,
            AppSettings.self,
            PageProgress.self,
            ReadingSession.self,
            Bookmark.self,
            ReaderAnnotation.self,
            BookCollection.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
        
    }
}
