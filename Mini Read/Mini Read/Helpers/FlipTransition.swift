//
//  FlipTransition.swift
//  FWTransition
//
//  Created by Balaji Venkatesh on 28/08/26.
//

import SwiftUI

/// Config
struct FlipTransitionConfig {
    var sourceCornerRadius: CGFloat = 12
    var destinationCornerRadius: CGFloat = 35
    var contextMenuTitle: String = "Edit"
    var contextMenuSymbol: String? = "pencil"
    var sourceExtendedBackgroundColor: Color = Color(UIColor.systemGray6)
}

struct FlipTransition<Content: View, Destination: View, ContextActions: View>: View {
    var config: FlipTransitionConfig = .init()
    /// 让源页面在展示期间退出命中测试。fullScreenCover 负责呈现，源页面负责
    /// 禁用其兄弟控件；只隐藏当前 source 视图挡不住同页的按钮。
    var onPresentationChange: (Bool) -> Void = { _ in }
    @ViewBuilder var content: Content
    @ViewBuilder var destination: (_ dismiss: @escaping () -> Void) -> Destination
    @ViewBuilder var contextActions: ContextActions
    /// View Properties
    @State private var sourceImage: UIImage?
    @State private var sourceRect: CGRect = .zero
    @State private var showDestination: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        content
            .contentShape(.contextMenuPreview, .rect(cornerRadius: config.sourceCornerRadius))
            .opacity(showDestination ? 0 : 1)
            /// Invisible is not the same as untappable: while the card is open this
            /// source view must leave the hit-test tree, otherwise a touch that falls
            /// through the presentation can land on it and re-run `expandDestination()`.
            .allowsHitTesting(!showDestination)
            .onGeometryChange(for: CGRect.self, of: {
                $0.frame(in: .global)
            }, action: { newValue in
                sourceRect = newValue
            })
            .onTapGesture {
                expandDestination()
            }
            .fullScreenCover(isPresented: $showDestination, onDismiss: {
                // 反向翻面完成后才恢复源页面；系统自行关闭时也走同一出口。
                onPresentationChange(false)
            }) {
                FlipDestinationView(
                    config: config,
                    sourceRect: $sourceRect,
                    sourceImage: $sourceImage,
                    destination: destination
                )
                /// if targeting iOS 27+ use this fail-case modifier as well!
                /// Incase transaction fails to not animate the full-screen-cover!
                /// NOTE: `.crossFade` is iOS 27+ only, uncomment it when you build with Xcode 27.
//                .navigationTransition(.crossFade)
            }
    }

    private func expandDestination() {
        guard !showDestination else { return }

        /// Creating Source Content Image using Image Renderer, instead of displaying the view again on the transition!
        let renderer = ImageRenderer(content:
            content
                /// Making sure that the color scheme matches!
                .environment(\.colorScheme, colorScheme)
        )
        renderer.proposedSize = .init(sourceRect.size)
        renderer.scale = displayScale
        sourceImage = renderer.uiImage
        /// A slight Delay!
        /// Increase delay if you want to start transition after the menu settles down!
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showDestination = true
                onPresentationChange(true)
            }
        }
    }
}

fileprivate struct FlipDestinationView<Destination: View>: View {
    var config: FlipTransitionConfig
    @Binding var sourceRect: CGRect
    @Binding var sourceImage: UIImage?
    @ViewBuilder var destination: (_ dismiss: @escaping () -> Void) -> Destination
    /// View Properties
    @State private var animate: Bool = false
    @State private var rotation: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GeometryReader {
            let size = $0.size
            let maxWidth = min(size.width * 0.88, 500)
            let maxHeight = min(size.height * 0.5, 500)

            let transformWidth = animate ? maxWidth : sourceRect.width
            let transformHeight = animate ? maxHeight : sourceRect.height

            let transformX = animate ? 0 : sourceRect.minX
            let transformY = animate ? 0 : sourceRect.minY

            let transformAlignment: Alignment = animate ? .center : .topLeading

            ZStack {
                Rectangle()
                    .fill(.clear)
                    /// Source
                    .overlay {
                        if let sourceImage {
                            Image(uiImage: sourceImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                /// Currently while filling, the source content stays at center, but you can change to top, if you wish so!
                                .frame(
                                    maxWidth: .infinity, maxHeight: .infinity,
                                    alignment: .center
                                )
                                /// When destination is larger than source, this property can be used to fill!
                                .background(config.sourceExtendedBackgroundColor)
                                .clipShape(.rect(cornerRadius: config.sourceCornerRadius))
                                .compositingGroup()
                                .modifier(FlipEffectModifier(
                                    isFlipped: false,
                                    progress: animate ? 1 : 0
                                ))
                        }
                    }
                    /// Destination
                    .overlay {
                        /// Scaling
                        /// Use Max for Aspect Fill, this is for fit!
                        let scale = min(transformWidth / maxWidth, transformHeight / maxHeight)

                        destination(dismissTransition)
                            .frame(width: maxWidth, height: maxHeight)
                            .scaleEffect(scale)
                            .frame(
                                width: transformWidth, height: transformHeight,
                                alignment: .top
                            )
                            /// Flipping Content, as it's rotated!
                            .scaleEffect(x: -1)
                            /// 玻璃背景（iOS 26 是 Liquid Glass，iOS 18 退化为材质，
                            /// 见 `glassSurface`）+ 空白区域命中层。
                            /// contentShape 只定义可命中的形状，本身不会消费触摸；
                            /// 独立空手势接住卡片空白处，书籍按钮与关闭按钮仍在它上面响应。
                            .background {
                                ZStack {
                                    Rectangle()
                                        .fill(.clear)
                                        .glassSurface(.regular, in: .rect(cornerRadius: config.destinationCornerRadius))

                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture { }
                                }
                            }
                            .clipShape(.rect(cornerRadius: config.destinationCornerRadius))
                            .contentShape(.rect(cornerRadius: config.destinationCornerRadius))
                            .compositingGroup()
                            .modifier(FlipEffectModifier(
                                isFlipped: true,
                                progress: animate ? 1 : 0
                            ))
                    }
            }
            .frame(width: transformWidth, height: transformHeight)
            .compositingGroup()
            .rotation3DEffect(
                .init(degrees: rotation),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.5
            )
            .offset(x: transformX, y: transformY)
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: transformAlignment
            )
            .ignoresSafeArea()
            /// Full-bleed scrim behind the card. It has to be part of the presented
            /// content to take part in hit testing: when it lived on
            /// `.presentationBackground` it only painted, so every touch outside the
            /// card fell through to the views behind the presentation.
            .background {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissTransition() }
            }
        }
        .presentationBackground {
            /// Paint only. The dismiss gesture lives on the scrim inside the content
            /// so there is a single source of truth for "tap outside to close".
            Rectangle()
                .fill(.black.opacity(animate ? 0.35 : 0))
        }
        .onAppear {
            animateTransition()
        }
    }

    func animateTransition() {
        guard !animate else { return }
        withAnimation(animation) {
            animate = true
            rotation = 180
        }
    }

    func dismissTransition() {
        guard animate else { return }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            animate = false
            rotation = 360
        } completion: {
            sourceImage = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dismiss()
            }
        }
    }

    /// Animation
    /// Customize it according to your own needs!
    var animation: Animation {
        .smooth(duration: 0.5, extraBounce: 0.1)
    }
}

/// Flip Modifier which will removes/adds view based on progress view!
/// NOTE: `@Animatable` macro is expanded manually here, so the file compiles
/// even on toolchains where macro plugins are unavailable.
fileprivate struct FlipEffectModifier: ViewModifier, Animatable {
    var isFlipped: Bool
    var progress: CGFloat

    /// `@AnimatableIgnored` equivalent for `isFlipped`
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(isFlipped ? (progress > 0.5 ? 1 : 0) : (progress > 0.5 ? 0 : 1))
    }
}
