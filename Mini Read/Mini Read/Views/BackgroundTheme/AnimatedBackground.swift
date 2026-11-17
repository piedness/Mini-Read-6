//
//  animatedBackgrounf.swift
//  vellium1218
//
//  Created by piednes on 2025-12-22.
//
import SwiftUI

// MARK: - 动态渐变背景
struct AnimatedGradientBackground: View {
    @State private var animateGradient = false
    
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
//                    colors: [
//                        Color(red: 0.08, green: 0.05, blue: 0.18),  // 深邃的靛紫色
//                        Color(red: 0.12, green: 0.08, blue: 0.25),  // 中间层紫色
//                        Color(red: 0.06, green: 0.12, blue: 0.28),  // 深蓝紫色
//                        Color(red: 0.10, green: 0.06, blue: 0.22)   // 柔和的紫色
//                    ],
                    
                    colors: [
                        Color(red: 0.05, green: 0.08, blue: 0.15),  // 深海蓝
                        Color(red: 0.08, green: 0.12, blue: 0.22),  // 午夜蓝
                        Color(red: 0.06, green: 0.15, blue: 0.25),  // 深钴蓝
                        Color(red: 0.04, green: 0.10, blue: 0.18)   // 深邃蓝
                    ],
                    
//                    colors: [
//                        Color(red: 0.12, green: 0.06, blue: 0.18),  // 深紫
//                        Color(red: 0.18, green: 0.08, blue: 0.25),  // 紫罗兰
//                        Color(red: 0.10, green: 0.08, blue: 0.22),  // 暗紫
//                        Color(red: 0.15, green: 0.06, blue: 0.20)   // 优雅紫
//                    ],
                    startPoint: animateGradient ? .topLeading : .bottomLeading,
                    endPoint: animateGradient ? .bottomTrailing : .topTrailing
                )
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                    animateGradient.toggle()
                }
            }
    }
}


