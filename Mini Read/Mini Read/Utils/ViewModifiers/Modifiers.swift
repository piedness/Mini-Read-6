//
//  listModify.swift
//  Vellium
//
//  Created by piednes on 23/04/2025.
//

import SwiftUI

struct CustomListModifier: ViewModifier{
    var title: String
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isRegular: Bool { hSizeClass == .regular }
    
    func body(content: Content) -> some View {
        Group {
            if isRegular {
                content
            } else {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }

    }
}




// 1. 定义一个包含模糊和透明度的 ViewModifier
struct BlurOpacityModifier: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    
    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
    }
}

// 2. 扩展 AnyTransition，方便调用
extension AnyTransition {
    static var customBlurReplace: AnyTransition {
        .modifier(
            active: BlurOpacityModifier(radius: 10, opacity: 0), // 消失时/出现前的状态：模糊度高，完全透明
            identity: BlurOpacityModifier(radius: 0, opacity: 1) // 正常显示时的状态：不模糊，不透明
        )
    }
}





