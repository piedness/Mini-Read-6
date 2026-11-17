//
//  Button.swift
//  TheNewVellium
//
//  Created by piednes on 2026-05-27.
//

import SwiftUI

struct ReaderToolbarButton: View {
    
    let systemImage: String
    let action: () -> Void
    
    var isVisible: Bool = true
    
    var isBold: Bool = true

    /// 不可用的按钮**留在原地变淡**，而不是消失：
    /// 阅读页右上/右下的控件位置是读者记住的，忽隐忽现会让整组按钮"跳"一下。
    var isEnabled: Bool = true

    /// 图标颜色。**必须跟随纸面明暗**（亮纸面黑、暗纸面白），由调用方从
    /// `ReadingTextTone.chromeControlInk` 取——不要在调用点自己判明暗。
    ///
    /// 为什么不用 `.primary`：`BookContent` 对整页施加的
    /// `preferredColorScheme` 是**与纸面相反**的（见
    /// `AppSettings.readerChromeColorScheme`），`.primary` 会随配色方案走，
    /// 一旦那条映射调整，按钮就会和纸面同色而看不见。
    var iconColor: Color = .black

    /// 玻璃表面的明暗，**必须与 `iconColor` 反着来**（黑图标配浅玻璃、白图标配深玻璃）。
    ///
    /// 为什么不能让它跟随环境：阅读页的 `preferredColorScheme` 与纸面相反，
    /// 材质会按环境解析成与纸面同向的深/浅，正好把图标吃掉。调用方从
    /// 纸面明暗（`ReadingTextTone`）直接给出，比在这里反推可靠。
    var surfaceTone: GlassSurfaceTone = .automatic

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .bold()
                .foregroundStyle(iconColor)
                // 视觉圆盘：读者看到的玻璃圆。
                //
                // 48×48 的胶囊与正圆是同一个形状；显式写 `Circle()` 是因为
                // 下面还有一层 `clipShape(Circle())`，两处用同一个形状，
                // 以后改尺寸也不会出现「玻璃是圆的、裁切是胶囊」的错位。
                .frame(
                    width: ReaderChromeMetrics.buttonSize,
                    height: ReaderChromeMetrics.buttonSize
                )
                .glassSurface(.clear, tone: surfaceTone, interactive: true, in: Circle())
                .clipShape(Circle())
                // 命中盒：把可点击范围向四周各扩 6pt（48 → 60）。
                //
                // 只改布局不改视觉——圆盘仍是上面那个 48 的圆，多出来的
                // 一圈完全透明。为什么不用 `.contentShape` 直接放大形状：
                // contentShape 的命中区域受视图自身 bounds 约束，画到框外
                // 不保证收得到触摸；把盒子做进布局才是确定生效的做法。
                //
                // 用矩形而不是圆形：四个角是最容易点偏的地方（尤其单手
                // 握持时拇指从屏幕边缘滑进来），矩形在角落多给的这点
                // 宽容度，正是"点不到"和"点到了"的差别。
                .frame(
                    width: ReaderChromeMetrics.buttonHitSize,
                    height: ReaderChromeMetrics.buttonHitSize
                )
                .contentShape(Rectangle())
        }
        // 玻璃按钮的按压反馈由 `GlassPressButtonStyle` 承担：
        // iOS 26 是空操作（玻璃的 `.interactive()` 已经给了反馈），
        // iOS 18 补一个克制的缩放。
        .buttonStyle(GlassPressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isVisible ? (isEnabled ? 1 : 0.4) : 0)
        .blur(radius: isVisible ? 0 : 8)
        .scaleEffect(isVisible ? 1 : 0.92)
        .allowsHitTesting(isVisible && isEnabled)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        // 换纸面时图标黑白对调，跟着做一次同长的淡变，不要硬切
        .animation(.easeInOut(duration: 0.2), value: iconColor)
    }
}

//Button(action: onImport) {
//    Image(systemName: "plus")
//        .font(.body)
//        .bold()
//        .foregroundStyle(.white)
//        .padding()
//        .frame(width: 40, height: 40)
//        .glassSurface(.regular, in: Circle())
//}
//.buttonStyle(GlassPressButtonStyle())
//.frame(width: 50, height: 50)
//.contentShape(Circle())
