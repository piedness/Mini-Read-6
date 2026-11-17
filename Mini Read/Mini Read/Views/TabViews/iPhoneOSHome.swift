import SwiftUI

/// 首页「继续读」：统计 → 最近在读 → 书单。
///
/// 标题与动作项在 `iPhoneOSTabs` 的导航栏里，本视图只负责内容。
/// 曾经这里手搓过一套顶部 chrome：把「Home」大标题塞进 ScrollView，
/// 再叠一层 `TopBlurOverlay` 去糊状态栏，并用外部传入的 `topInset`
/// 把标题顶到与浮层按钮同一高度。三个视图抢同一条顶带的结果就是
/// 滚动时内容从按钮底下穿过去；那套 `topInset` 还因为初值为 0，
/// 在启动首帧把标题放在 y=5，下一帧才跳到安全区下方。
///
/// 现在这些都交给系统：大标题在导航栏里随滚动收缩，内容滚到栏下时
/// 由系统给 scroll edge effect，不再需要对 `UIVisualEffectView` 二次模糊。
struct iPhoneOSHomeView: View {

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ReadingStatsRow()

                RecentCardView()

                CollectionView()
            }
            .padding(.horizontal, 20)
            .padding(.vertical)
            // 底部留白交给 ScrollView 的安全区 inset（浮动 tab bar 已计入），
            // 这里只补一点内容与栏之间的呼吸，不再用 180pt 的假占位硬顶。
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }
}
