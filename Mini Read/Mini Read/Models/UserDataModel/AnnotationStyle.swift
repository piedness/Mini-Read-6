//
//  AnnotationStyle.swift
//  TheNewVellium
//
//  标注的外观语义：样式（底色 / 下划线 / 波浪线 / 删除线）与颜色。
//
//  只存 `rawValue`（见 ReaderAnnotation），不存 UIColor：
//  - 颜色要随纸面明暗解析，存具体色值会让夜读纸面上出现一块刺眼的浅色；
//  - 透明度是全局设置（`AppSettings.highlightOpacity`），存在记录里的话，
//    读者调整一次透明度，旧标注不会跟着变。
//

import SwiftUI
import UIKit

// MARK: - 样式

enum AnnotationStyle: String, CaseIterable, Identifiable, Sendable {

    /// 背景底色（默认）
    case highlight
    /// 下划线
    case underline
    /// 波浪线（校样/强调语义）
    case wavy
    /// 删除线
    case strikethrough

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highlight:     return "高亮"
        case .underline:     return "下划线"
        case .wavy:          return "波浪线"
        case .strikethrough: return "删除线"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight:     return "highlighter"
        case .underline:     return "underline"
        case .wavy:          return "waveform.path"
        case .strikethrough: return "strikethrough"
        }
    }
}

// MARK: - 颜色

enum AnnotationColor: String, CaseIterable, Identifiable, Sendable {

    case yellow
    case green
    case blue
    case pink
    case orange

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yellow: return "黄色"
        case .green:  return "绿色"
        case .blue:   return "蓝色"
        case .pink:   return "粉色"
        case .orange: return "橙色"
        }
    }

    /// 标注用色。
    ///
    /// 动态颜色：暗纸面上用系统色即可（系统色本身会提亮），浅纸面上压一点饱和度，
    /// 避免高亮区比正文还抢眼。透明度不在这里烘焙——它来自用户设置，
    /// 由绘制层统一乘上去（见 `AnnotationDrawing`）。
    var uiColor: UIColor {
        switch self {
        case .yellow:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.systemYellow
                    : UIColor(red: 0.98, green: 0.80, blue: 0.24, alpha: 1)
            }
        case .green:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.systemGreen
                    : UIColor(red: 0.42, green: 0.76, blue: 0.45, alpha: 1)
            }
        case .blue:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.systemBlue
                    : UIColor(red: 0.36, green: 0.60, blue: 0.92, alpha: 1)
            }
        case .pink:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.systemPink
                    : UIColor(red: 0.93, green: 0.52, blue: 0.66, alpha: 1)
            }
        case .orange:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.systemOrange
                    : UIColor(red: 0.95, green: 0.62, blue: 0.28, alpha: 1)
            }
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// 菜单里的小圆点。`alwaysOriginal` 保证菜单不会把它染成系统蓝。
    func menuImage() -> UIImage? {
        UIImage(systemName: "circle.fill")?
            .withTintColor(uiColor, renderingMode: .alwaysOriginal)
    }
}
