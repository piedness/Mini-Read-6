//
//  BookContent.swift
//  swiftUI0907
//
//  Created by Max Piednes on 2025/9/14.
//

import SwiftUI
import SwiftData
import UIKit


struct BookContentView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var contentsViewModel: ContentsPanelViewModel

    /// 只为让本视图在设置变化时重新求值；取值仍走 `modelContext.appSettings()` 唯一入口。
    @Query private var settings: [AppSettings]

    init(book: bookItem, modelContext: ModelContext) {
        self.book = book
        _contentsViewModel = StateObject(
            wrappedValue: ContentsPanelViewModel(book: book, modelContext: modelContext)
        )
    }
    let book: bookItem
    
    @State private var isShowBackArrow: Bool = false
    @State private var isShowContentPanel: Bool = false
    @State private var toolbarHideTask: Task<Void, Never>?
    /// 阅读页出现前的系统 idle timer 状态；关闭阅读器/离开前台时原样恢复。
    @State private var previousIdleTimerDisabled: Bool?
    @State private var sessionStart: Date?
    private let sessionMergeGapSeconds: TimeInterval = 30
    
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isRegular: Bool { hSizeClass == .regular }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 加载态与阅读器互换的过渡。
    ///
    /// **只淡隐，不缩放**：缩放整页正文会让读者以为纸面尺寸变了，
    /// 而这里的重点是"字突然出现了"，位移与缩放都是多余表演。
    /// 曲线沿用工程基线（单曲线 easeOut，进出共用），reduceMotion 再收短。
    private var readerRevealAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.22)
    }

    /// `fullScreenCover` 的 zoom 转场静默窗。
    ///
    /// 为什么不直接在 `canOpenReader` 一变 true 就把阅读器建出来：
    /// 那时 zoom 转场往往还在跑，于是「销毁 ProgressView」与「构造整套 UIKit
    /// 页面层级」（`setupPageVC` + 音量键装配）撞进同一帧，主线程被占住，
    /// 转场动画掉帧。首次打开 EPUB 解析刚好落在这个窗口里，所以只有首次最明显。
    ///
    /// 这个窗是**保守估计**，取系统 zoom 转场的典型时长。
    /// 它不改变"内容何时就绪"，只把"构造层级"这件事推到转场结束后的安静帧里。
    /// reduceMotion 下转场近乎瞬时，窗也相应收短到 0。
    private static let coverTransitionSettleDelay: TimeInterval = 0.45

    /// 转场是否已静默。见 `scheduleTransitionSettle`。
    @State private var hasTransitionSettled = false
    /// 静默窗任务句柄。必须是 `@State`：普通属性在 View 的方法里赋值 `self` 不可变。
    @State private var settleTask: Task<Void, Never>?

    /// 真正该显示阅读器的条件：数据就绪 **且** 转场已静默。
    ///
    /// 两者缺一不可。早了 → 构造层级撞转场（掉帧）；晚了 → 白白多转一圈
    /// ProgressView。而绝大多数小书解析在 100ms 内完成，静默窗几乎总是先满足，
    /// 不会让读者多等。
    private var shouldPresentReader: Bool {
        contentsViewModel.canOpenReader && hasTransitionSettled
    }

    /// 阅读页当前的三种形态。用它作为动画的身份值：
    /// 失败卡片必须在同一帧里替换掉加载指示，而不是等下一次无关刷新。
    private enum ReaderPhase: Equatable {
        case loading
        case failed
        case ready
    }

    private var readerPhase: ReaderPhase {
        if shouldPresentReader { return .ready }
        return contentsViewModel.loadFailure == nil ? .loading : .failed
    }

    /// 所有可见设置均走 modelContext.appSettings() 唯一入口；@Query 仅用于让视图观察变更。
    private var readerSettings: AppSettings {
        settings.first ?? modelContext.appSettings()
    }

    /// 阅读器外围系统界面的配色方案：随纸面明暗变化。
    /// 映射规则收在 `AppSettings.readerChromeColorScheme`，这里不重复判断。
    private var chromeScheme: ColorScheme {
        readerSettings.readerChromeColorScheme
    }

    /// 阅读页三个浮动按钮的图标颜色：**跟随纸面明暗**。
    ///
    /// 亮纸面（正文用深墨）配黑图标、暗纸面（正文用浅墨）配白图标。
    /// 取值收在 `ReadingTextTone.chromeControlInk`，与正文墨色共用同一套
    /// 亮度判定——不要在视图里另算一次明暗。
    private var readerControlInk: Color {
        readerSettings.readingTextTone.chromeControlInk
    }

    /// 浮动按钮玻璃表面的明暗：与图标墨色**相反**。
    ///
    /// 亮纸面 → 浅玻璃 + 黑图标；暗纸面 → 深玻璃 + 白图标。
    /// 阅读页的 chrome 配色与纸面相反，材质若跟随环境就会解析成同向的深/浅，
    /// 把图标吃掉（见 `ReaderToolbarButton.surfaceTone`），所以这里显式给值。
    private var readerSurfaceTone: GlassSurfaceTone {
        readerSettings.readingTextTone == .dark ? .light : .dark
    }
    
    
    var body: some View {
        ZStack{
            if shouldPresentReader {
                PageViewControllerRepresentable(
                    currentSrc: contentsViewModel.currentSrc,
                    allSrcs: contentsViewModel.allSrcs,
                    epubBaseURL: contentsViewModel.book.resourceBaseURL,
                    bookKey: contentsViewModel.book.bookExtrSubdir.path,
                    // 扉页（封面/书名/作者）数据源。封面指向解压目录内的图片文件，
                    // 读不到时扉页退化为纯文字排版。
                    bookTitle: contentsViewModel.book.bookTitle,
                    bookAuthor: contentsViewModel.book.bookAuthor,
                    coverImageURL: contentsViewModel.book.coverImageURLs.first,
                    titleBySrc: contentsViewModel.titleBySrc,
                    tocJumpRequest: contentsViewModel.tocJumpRequest,
                    derivedVersion: contentsViewModel.derivedVersion,
                    onChapterChange: { src in
                        contentsViewModel.selectBySrc(src)
                    },
                    onFirstPageShown: {
                        // 第一页上屏 → 转场早已结束、UIKit 层级也已建完，
                        // 此刻才把静默窗内登记的写入一次性提交。
                        contentsViewModel.openWriteGateAndCommit()
                    },
                    onLocationChange: { location in
                        // UIKit 侧可能在 SwiftUI 的更新事务里回调（目录 / 书签跳转
                        // 会同步走到 showPages），直接改 @Published 会撞上
                        // "在视图更新期间修改状态"。挪到下一个 main actor turn。
                        Task { @MainActor in
                            contentsViewModel.updateCurrentLocation(location)
                            // 「已读」跟着**真正上屏的可锚定页**走，而不是
                            // `currentSrc` 一变就记：目录点到一个文件缺失的章
                            // 时 currentSrc 会先改，加载失败回退后那一章却已经
                            // 被标成已读（下次打开永远显示已读、父章进度偏大）。
                            // 扉页 / 空白页没有锚点（location == nil），等读者
                            // 翻到正文页再记。
                            if let src = location?.src {
                                contentsViewModel.markChapterReadIfNeeded(forSrc: src)
                            }
                        }
                    }
                )
                .simultaneousGesture(TapGesture().onEnded {
                    toggleReaderChrome()
                    if isShowContentPanel {
                        setContentPanelVisible(false)
                    }
                })
                // 交叉淡入的关键：transition 挂在**各自内容**上，
                // 动画则挂在下方 ZStack 这个共同祖先上。
                // 缺任一边都不行——只有 transition 没有动画，等于硬切。
                .transition(.opacity)
            } else if let failure = contentsViewModel.loadFailure {
                // 打不开：给出原因、重试与移除出口，而不是无限转圈。
                ReaderOpenFailureView(
                    bookTitle: contentsViewModel.book.bookTitle,
                    failure: failure,
                    onRetry: { contentsViewModel.retryLoading() },
                    onRemove: { removeBookAndClose() },
                    onClose: { dismiss() }
                )
                .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .transition(.opacity)
            }
            
            // 目录 float panel
            if isShowContentPanel {
                //iPad 目录面板动画：
                if isRegular{
                    ElegantTOCPanel(viewModel: contentsViewModel) {
                        // ✅ 选章节后，带动画关闭面板
                        withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
                            setContentPanelVisible(false)
                        }
                    }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.regularMaterial)
                        )
                        .frame(width: 600,height: 550)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.88, anchor: .center)
                                    .combined(with: .opacity),
                                removal: .scale(scale: 0.88, anchor: .center)
                                    .combined(with: .opacity)
                            )
                        )
                        .zIndex(1)
                }
            }
        }
        // 加载态 ↔ 阅读器的交叉淡入挂在 **ZStack（两者的共同祖先）** 上，
        // value 取三态身份（加载 / 失败 / 就绪）——它翻转的次数一只手数得清，
        // 不会像绑定 @Published 那样被每帧的无关 body 求值反复触发。
        .animation(readerRevealAnimation, value: readerPhase)
        .ignoresSafeArea()
        .preferredColorScheme(chromeScheme)
        .sheet(isPresented: Binding(
            get: { isShowContentPanel && !isRegular },
            set: { setContentPanelVisible($0) }
        )){
            ElegantTOCPanel(viewModel: contentsViewModel) {
                // ✅ 选章节后，带动画关闭面板
                withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
                    setContentPanelVisible(false)
                }
            }
                .presentationDetents([.medium, .large])   // 支持半屏 / 全屏两档
                .presentationDragIndicator(.visible)       // 显示系统抓手
        }
        // MARK: - 浮动控件
        //
        // 三个按钮（书签 / 目录 / 关闭）的**视觉圆盘**都是 48，
        // 可点击范围由 `ReaderToolbarButton` 内部的 60×60 命中盒提供。
        // 因此这里的每个内边距 / 间距都是「命中盒」口径：
        // 已经扣掉 6pt 的扩张量，圆盘位置与改版前逐像素一致。
        .overlay{
            //iPadOS 按钮布局：三个按钮都在右上角、贴安全区上沿
            if isRegular{
                VStack{
                    // 间距用 `Pad.buttonSpacing`（20 - 12）：命中盒比圆盘宽 12，
                    // 沿用 20 会把圆盘撑开到 32，三个按钮看上去像散开了。
                    HStack(spacing: ReaderChromeMetrics.Pad.buttonSpacing){
                        Spacer()
                        bookmarkButton
                        TableButton
                        
                        dismissButton
                    }
                    .padding(.horizontal, ReaderChromeMetrics.Pad.buttonEdgeInset)
                    
                    Spacer()
                }
                
            }else{
                //iPhoneOS 按钮布局：按钮贴屏幕边（chrome VStack ignoresSafeArea），
                // 内边距取自 `ReaderChromeMetrics.Phone`：阅读页的页码/标题元素
                // 与这两个按钮「圆盘中心对齐」，两侧共用同一组常量才不会各改各的。
                VStack{
                    HStack {
                        
                        Spacer()
                        dismissButton
                            .padding(ReaderChromeMetrics.Phone.buttonEdgeInset)
                            .padding(.top, ReaderChromeMetrics.Phone.topButtonTopInset)
                    }

                    
                    Spacer()
                    
                    // 书签按钮在目录按钮左侧：两者同高、同内边距，
                    // 底部页码（`bottomCenterOffset`）才能继续与这一组对齐。
                    HStack(spacing: 14) {
                        bookmarkButton
                        Spacer()
                        TableButton
                    }
                    .padding(ReaderChromeMetrics.Phone.bottomButtonInset)
                }
                .ignoresSafeArea()

            }
            
        }
        .onAppear {
            startReadingSessionIfNeeded()
            syncIdleTimerForScenePhase()
            scheduleTransitionSettle()
        }
        // 阅读会话（以及 `lastOpenedAt`）只在**书真的打开之后**才开始。
        //
        // 原先挂在 onAppear：解析失败的书也会被记一次「最近打开」，
        // 读者盯着错误页看的时间还会被算进阅读统计。现在等第一页就绪。
        .onChange(of: shouldPresentReader) { _, ready in
            if ready { startReadingSessionIfNeeded() }
        }
        // 「已读」的写入点已收敛到阅读器上报的可见页位置（见上方
        // `onLocationChange`）。不能再挂 `currentSrc`：它是"请求到的章"，
        // 在加载完成之前就会改变，失败回退时会把没读到的章也标成已读。
        .onDisappear {
            settleTask?.cancel()
            cancelToolbarHideTask()
            restoreIdleTimer()
            // 兜底：读者若在"第一页上屏"之前就退出（加载失败、秒退），
            // 静默窗内登记的写入不能跟着 VM 一起消失。
            contentsViewModel.openWriteGateAndCommit()
            // 章切换后 1.5s 内退出：防抖任务会随 VM 释放被取消，
            // 这里补一次同步落盘，别让 lastReadSrc 退回上一章。
            contentsViewModel.flushPendingPersistence()
            flushReadingSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                syncIdleTimerForScenePhase()
                startReadingSessionIfNeeded()
            case .inactive, .background:
                // 离开前台时恢复系统原始息屏策略；重新激活时再按设置应用。
                restoreIdleTimerForInactiveScene()
                cancelToolbarHideTask()
                // 进后台同样先开闸：此刻多半是被系统打断，等不到第一页上屏。
                contentsViewModel.openWriteGateAndCommit()
                // 同理：被系统打断时防抖任务可能还没跑，落盘一次再走。
                contentsViewModel.flushPendingPersistence()
                flushReadingSession()
            @unknown default:
                break
            }
        }
        .onChange(of: settings.first?.keepScreenOn ?? false) { _, _ in
            syncIdleTimerForScenePhase()
        }
        .onChange(of: settings.first?.autoHideToolbar ?? true) { _, enabled in
            if enabled {
                scheduleToolbarAutoHide()
            } else {
                cancelToolbarHideTask()
            }
        }
        .onChange(of: settings.first?.toolbarHideDelay ?? 3.0) { _, _ in
            scheduleToolbarAutoHide()
        }

    }
    
    // MARK: - 阅读器控件与辅助设置

    private var keepScreenOnEnabled: Bool {
        readerSettings.keepScreenOn
    }

    /// 单击纸面显示/隐藏阅读控件；延迟从用户当前设置读取。
    private func toggleReaderChrome() {
        setReaderChromeVisible(!isShowBackArrow)
    }

    private func setReaderChromeVisible(_ visible: Bool) {
        isShowBackArrow = visible
        if visible {
            scheduleToolbarAutoHide()
        } else {
            cancelToolbarHideTask()
        }
    }

    private func setContentPanelVisible(_ visible: Bool) {
        isShowContentPanel = visible
        if visible {
            // 目录面板显示期间，保留控件可见但暂停自动隐藏。
            isShowBackArrow = true
            cancelToolbarHideTask()
        } else if isShowBackArrow {
            scheduleToolbarAutoHide()
        }
    }

    private func scheduleToolbarAutoHide() {
        cancelToolbarHideTask()
        guard isShowBackArrow,
              !isShowContentPanel,
              readerSettings.autoHideToolbar
        else { return }

        let delay = max(1, min(10, readerSettings.toolbarHideDelay))
        toolbarHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, !isShowContentPanel, readerSettings.autoHideToolbar else { return }
            isShowBackArrow = false
            toolbarHideTask = nil
        }
    }

    private func cancelToolbarHideTask() {
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
    }

    /// 只在阅读页可见且 App 活跃时施加常亮覆盖；保留并恢复进入阅读器前的系统值。
    private func syncIdleTimerForScenePhase() {
        guard scenePhase == .active else {
            restoreIdleTimerForInactiveScene()
            return
        }
        if previousIdleTimerDisabled == nil {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = keepScreenOnEnabled
            ? true
            : (previousIdleTimerDisabled ?? false)
    }

    private func restoreIdleTimerForInactiveScene() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    private func restoreIdleTimer() {
        restoreIdleTimerForInactiveScene()
        previousIdleTimerDisabled = nil
    }

    // MARK: - 目录控件
    @ViewBuilder
    private var TableButton: some View {
        ReaderToolbarButton(
            systemImage: "list.dash",
            action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    setContentPanelVisible(!isShowContentPanel)
                }
            },
            isVisible: isShowBackArrow,
            isBold: true,
            iconColor: readerControlInk,
            surfaceTone: readerSurfaceTone
        )
        .accessibilityLabel("目录")
    }

    // MARK: - 书签控件

    /// 当前页是否已加书签。图标在空心/实心之间切换，本身就是状态提示。
    private var isCurrentPageBookmarked: Bool {
        contentsViewModel.isCurrentPageBookmarked
    }

    /// 「添加书签」。位置固定在目录按钮左侧（见 overlay 两个分支）。
    ///
    /// 不可锚定的页面（扉页、空白页、内容未上屏）禁用而不是隐藏：
    /// 按钮忽隐忽现比暂时不可用更让人困惑，而禁用的原因对读者是显然的——
    /// 这一页本来就没有正文可标记。
    @ViewBuilder
    private var bookmarkButton: some View {
        ReaderToolbarButton(
            systemImage: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
            action: { contentsViewModel.toggleBookmarkAtCurrentPage() },
            isVisible: isShowBackArrow,
            isBold: false,
            isEnabled: contentsViewModel.currentLocation != nil,
            iconColor: readerControlInk,
            surfaceTone: readerSurfaceTone
        )
        .accessibilityLabel(isCurrentPageBookmarked ? "移除书签" : "添加书签")
        .accessibilityValue(isCurrentPageBookmarked ? "当前页已加书签" : "")
    }

    @ViewBuilder
    private var dismissButton: some View {
        ReaderToolbarButton(
            systemImage: "xmark",
            action: {
                dismiss()
            },
            isVisible: isShowBackArrow,
            isBold: false,
            iconColor: readerControlInk,
            surfaceTone: readerSurfaceTone
        )
        // 显式标签：SF Symbol `xmark` 本身没有语义，VoiceOver 只会念出
        // "X 标记"。另两个按钮早就带了标签，这里补齐才是一组。
        .accessibilityLabel("关闭阅读器")
    }
    
    

    /// 等 fullScreenCover 的 zoom 转场结束，再放行阅读器的构造。
    ///
    /// 这是根因 A 的修复：在转场还在跑的时候就把 `PageViewControllerRepresentable`
    /// 建出来，等于让"构造整套 UIKit 页面层级"和"跑转场动画"抢同一帧的主线程，
    /// 于是掉帧。这里把构造推迟到转场静默之后，落在安静的帧里。
    ///
    /// 用 `Task.sleep` 而不是 `DispatchQueue.main.asyncAfter`：
    /// 前者随视图消失一起取消（见 `onDisappear`），不会在阅读器已关闭后
    /// 仍去改 `@State`。
    private func scheduleTransitionSettle() {
        settleTask?.cancel()
        // reduceMotion 下 zoom 转场近乎瞬时，没有等待的必要。
        let delay = reduceMotion ? 0.0 : Self.coverTransitionSettleDelay
        guard delay > 0 else {
            hasTransitionSettled = true
            return
        }
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            hasTransitionSettled = true
        }
    }

    private func startReadingSessionIfNeeded() {
        // 只有书真的能读时才记会话：失败态下的停留不是阅读，
        // 既不该进「最近打开」，也不该进阅读时长。
        guard contentsViewModel.canOpenReader else { return }
        guard sessionStart == nil else { return }
        sessionStart = .now
        // `lastOpenedAt` 的写入交给 VM 的转场静默窗（见 `markOpenedIfNeeded`）：
        // 此刻 zoom 转场往往还没结束，直接落盘会触发书架重绘。
        contentsViewModel.markOpenedIfNeeded()
    }

    /// 错误页上的「从书库移除」。
    ///
    /// 先掐掉本次阅读会话：`onDisappear` 会调 `flushReadingSession`，
    /// 而它要写 `book.lastOpenedAt`——书已经删了，不能再碰。
    /// 删除本身由 VM 负责（停后台写入 → 删模型 → 清磁盘）。
    private func removeBookAndClose() {
        sessionStart = nil
        contentsViewModel.removeBookFromLibrary()
        dismiss()
    }

    private func flushReadingSession() {
        guard let start = sessionStart else { return }
        let end = Date()
        let duration = max(0, Int(end.timeIntervalSince(start)))
        sessionStart = nil

        // Ignore accidental blips when quickly opening/closing.
        guard duration >= 5 else { return }

        upsertReadingSession(start: start, end: end, duration: duration)
        book.lastOpenedAt = end
        try? modelContext.save()
    }

    private func upsertReadingSession(start: Date, end: Date, duration: Int) {
        let key = book.bookExtrSubdir.lastPathComponent
        var descriptor = FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.bookKey == key }
        )
        descriptor.sortBy = [SortDescriptor(\.endedAt, order: .reverse)]
        descriptor.fetchLimit = 1

        if let latest = try? modelContext.fetch(descriptor).first,
           start.timeIntervalSince(latest.endedAt) <= sessionMergeGapSeconds {
            latest.endedAt = end
            latest.durationSeconds = max(0, Int(latest.endedAt.timeIntervalSince(latest.startedAt)))
            return
        }

        let session = ReadingSession(
            bookKey: key,
            bookTitle: book.bookTitle,
            startedAt: start,
            endedAt: end,
            durationSeconds: duration
        )
        modelContext.insert(session)
    }
}
