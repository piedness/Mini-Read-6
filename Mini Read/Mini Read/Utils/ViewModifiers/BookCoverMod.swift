//
//  BookCoverMod.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/5/31.
//

import SwiftUI

// MARK: - Premium Hardcover Modifier (法式书槽精装版)
struct PremiumHardcoverModifier: ViewModifier {
    
    // 精装书的圆角通常稍微硬朗一些，彰显力量感
    private let cornerRadius: CGFloat = 4
    
    func body(content: Content) -> some View {
        content
            // 1. 基础裁切
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                ZStack {
                    // 2. 模拟硬纸板边缘的光线折射 (3D Bevel)
                    // 使用带有方向性的渐变描边，左上亮，右下暗，瞬间拉出厚度
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.6), .clear, .black.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                        .blendMode(.overlay)
                    
                    // 3. 核心创新：法式书槽 (The French Groove) - 极致克制版
                    // 将透明度降至“隐形”的边缘，仅保留最微弱的空间结构信息
                    LinearGradient(
                        stops: [
                            // A. 书脊向后的极微弱翻折包裹感
                            .init(color: .black.opacity(0.08), location: 0.0),
                            // B. 书槽左侧极淡的光晕 (几乎与封面融为一体)
                            .init(color: .white.opacity(0.03), location: 0.02),
                            // C. 凹槽暗部 (降至 0.15，彻底摆脱“脏污”感，仅留物理深度)
                            .init(color: .black.opacity(0.15), location: 0.045),
                            // D. 凹槽右侧高光 (降至 0.1，模拟哑光纸张的微弱折射，不刺眼)
                            .init(color: .white.opacity(0.12), location: 0.055),
                            // E. 高光向右侧平面的极长、极淡的漫反射过渡
                            .init(color: .black.opacity(0.02), location: 0.08),
                            .init(color: .clear, location: 0.15)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .blendMode(.overlay) // 依然使用 overlay，保证颜色自适应
                    
                    // 4. 表面特种纸光泽 (Premium Sheen)
                    // 一道横跨封面的对角线柔和反光，打破平面的死板
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .white.opacity(0.15), location: 0.3),
                            .init(color: .clear, location: 0.6)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blendMode(.screen)
                }
                // 叠加层自己收在圆角里。
                //
                // 这一步不能挪到最外层去"统一裁一次"：`.shadow` 之后再 `.clipShape`
                // 会把影一起裁掉（实测：影区亮度 255，与纯白无差），下面两层影就白写了。
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            // 5. 博物馆展柜级的阴影系统 (Exhibition Shadows)
            // 接触影：极度紧贴，模拟书本本身的绝对重量
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
            // 悬浮影：大范围的柔和环境光遮蔽，仿佛书本被放置在柔光灯下
            .shadow(color: .black.opacity(0.15), radius: 15, x: 5, y: 10)
    }
}

// MARK: - View Extension 方便调用
extension View {
    /// 应用自定义的博物馆级精装书物理质感
    func premiumHardcoverStyle() -> some View {
        self.modifier(PremiumHardcoverModifier())
    }
}
