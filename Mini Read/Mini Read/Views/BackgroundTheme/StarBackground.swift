import SwiftUI
internal import Combine

/// 星空动态背景视图 - 飞船窗口视角
/// 设计理念:模拟宇宙飞船向前飞行,星星从中心向四周扩散
struct StarryBackgroundView: View {
    @State private var stars: [Star] = []
    @State private var shootingStars: [ShootingStar] = []
    @State private var animationTime: TimeInterval = 0
    
    let starCount: Int = 100
    let baseColor: Color = Color(red: 0.05, green: 0.05, blue: 0.15)
    let timer = Timer.publish(every: 1/60, on: .main, in: .common).autoconnect()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                // 使用Canvas绘制动态星星
                Canvas { context, size in
                    let centerX = size.width / 2
                    let centerY = size.height / 2
                    
                    for star in stars {
                        // 计算星星从中心向外扩散的位置
                        let progress = star.depth
                        let x = centerX + (star.normalizedX * size.width * progress)
                        let y = centerY + (star.normalizedY * size.height * progress)
                        
                        // 根据深度计算大小(越近越大)
                        let scaledSize = star.baseSize * (0.5 + progress * 1.5)
                        
                        // 根据深度计算透明度(越近越亮)
                        let opacity = min(1.0, 0.3 + progress * 0.7)
                        
                        // 绘制星星
                        let rect = CGRect(
                            x: x - scaledSize / 2,
                            y: y - scaledSize / 2,
                            width: scaledSize,
                            height: scaledSize
                        )
                        
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(.white.opacity(opacity))
                        )
                        
                        // 为较近的星星添加光晕效果
                        if progress > 0.7 {
                            let glowRect = CGRect(
                                x: x - scaledSize,
                                y: y - scaledSize,
                                width: scaledSize * 2,
                                height: scaledSize * 2
                            )
                            context.fill(
                                Path(ellipseIn: glowRect),
                                with: .color(.white.opacity(0.1 * progress))
                            )
                        }
                    }
                }
                
                // 流星
                ForEach(shootingStars) { shootingStar in
                    ShootingStarShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.8),
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: shootingStar.length, height: 2)
                        .position(shootingStar.position)
                        .rotationEffect(.degrees(shootingStar.angle))
                        .opacity(shootingStar.opacity)
                }
            }
            .onAppear {
                initializeStars(in: geometry.size)
                startShootingStars(in: geometry.size)
            }
            .onReceive(timer) { _ in
                updateStars(in: geometry.size)
            }
        }
    }
    
    // 初始化星星
    private func initializeStars(in size: CGSize) {
        stars = (0..<starCount).map { _ in
            // 在整个屏幕空间随机生成初始位置
            let initialX = Double.random(in: -1.2...1.2)
            let initialY = Double.random(in: -1.2...1.2)
            
            return Star(
                normalizedX: initialX,
                normalizedY: initialY,
                depth: Double.random(in: 0...1),
                baseSize: CGFloat.random(in: 0.5...0.8),
                speed: Double.random(in: 0.0005...0.001)
            )
        }
    }
    
    // 更新星星位置
    private func updateStars(in size: CGSize) {
        for index in stars.indices {
            // 增加深度,模拟向前移动
            stars[index].depth += stars[index].speed
            
            // 当星星移出屏幕时,重置到远处(depth=0)
            if stars[index].depth > 1.5 {
                // 在整个屏幕空间随机重新生成位置
                stars[index].normalizedX = Double.random(in: -1.2...1.2)
                stars[index].normalizedY = Double.random(in: -1.2...1.2)
                stars[index].depth = 0
                stars[index].baseSize = CGFloat.random(in: 0.5...1.5)
                stars[index].speed = Double.random(in: 0.001...0.005)
            }
        }
    }
    
    // 流星动画
    private func startShootingStars(in size: CGSize) {
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            createShootingStar(in: size)
        }
    }
    
    private func createShootingStar(in size: CGSize) {
        let startX = CGFloat.random(in: size.width * 0.4...size.width)
        let startY = CGFloat.random(in: 0...size.height * 0.4)
        
        let shootingStar = ShootingStar(
            position: CGPoint(x: startX, y: startY),
            length: CGFloat.random(in: 60...100),
            angle: Double.random(in: -45...(-35)),
            opacity: 0
        )
        
        shootingStars.append(shootingStar)
        
        // 淡入
        withAnimation(.easeIn(duration: 0.1)) {
            if let index = shootingStars.firstIndex(where: { $0.id == shootingStar.id }) {
                shootingStars[index].opacity = 1.0
            }
        }
        
        // 移动
        withAnimation(.linear(duration: 1.5)) {
            if let index = shootingStars.firstIndex(where: { $0.id == shootingStar.id }) {
                shootingStars[index].position = CGPoint(
                    x: startX - 400,
                    y: startY + 400
                )
            }
        }
        
        // 淡出并移除
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation(.easeOut(duration: 0.2)) {
                if let index = shootingStars.firstIndex(where: { $0.id == shootingStar.id }) {
                    shootingStars[index].opacity = 0
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                shootingStars.removeAll { $0.id == shootingStar.id }
            }
        }
    }
}

// MARK: - 数据模型

struct Star: Identifiable {
    let id = UUID()
    var normalizedX: Double  // 归一化的X方向(-1到1)
    var normalizedY: Double  // 归一化的Y方向(-1到1)
    var depth: Double        // 深度(0=中心, 1=边缘)
    var baseSize: CGFloat    // 基础大小
    var speed: Double        // 移动速度
}

struct ShootingStar: Identifiable {
    let id = UUID()
    var position: CGPoint
    var length: CGFloat
    var angle: Double
    var opacity: Double
}

// MARK: - 流星形状

struct ShootingStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

// MARK: - 预览

struct StarryBackgroundView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            StarryBackgroundView()
                .ignoresSafeArea()
        }
    }
}
