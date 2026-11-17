//
//  VolumeKeyPager.swift
//  TheNewVellium
//
//  把音量键变成翻页键。
//
//  ## 检测（两条互相独立的通道，任一命中都算一次按键）
//  1. `AVAudioSession.outputVolume` 的 KVO——**公开属性**，文档明确可用 KVO 观察。
//     主通道：不碰私有子视图，不会因 MPVolumeView 内部实现变化而失效。
//  2. `MPVolumeView` 内部滑块的 `.valueChanged`——对硬件按键最灵敏的落点，做备份。
//     （程序化 setValue 不会触发它，所以"拨回音量"没有自触发问题。）
//  两条都汇到 `observe(volume:from:)`，用 `lastObservedVolume` 去重：两路同响只翻一页。
//
//  ## 音量键路由到"媒体音量"的两个前提（缺一个，两条通道都永远不响）
//  A. 音频会话必须激活（`.playback` + `.mixWithOthers`：路由到媒体音量、不打断别处音频）。
//  B. **必须有音频处于"正在播放"状态**。会话活跃但没有任何声音在播时，系统会把音量键
//     留给铃声（iPhone 默认「用侧边键调整」），媒体音量纹丝不动。
//     所以这里常驻一段**内存生成的静音音频**（全零 WAV，循环播放，听不见），
//     让会话保持"播放中"——这是音量键翻页类功能的通行做法。
//
//  ## 拨回（检测的代价）
//  检测建立在"音量变了"之上，按键必然改动系统音量，所以检测到后要立刻拨回
//  `referenceVolume`。公开 API 里唯一能设置系统音量的手段就是 MPVolumeView 的内部
//  滑块；必须**异步**写回（同步写回会被吞、音量一路漂走）。顺带：层级里存在屏幕外的
//  MPVolumeView 时，系统音量 HUD 被顶替，按键不会闪音量框。
//
//  ## 滑块是"惰性构建"的（重要）
//  刚 addSubview 时拿不到内部滑块；它可能在布局后、进 window 后才出现。
//  因此：**滑块找不到绝不放弃本功能**（KVO 通道独立存活），改为多时机重试
//  （立即 / 进 window 回调 / 0.25s×12 定时 / 每次按键时再试）。
//
//  ## 已知边界
//  - 音量贴边时启动内挪 1/16（约 6%，听不出）留出双向余量——唯一轻微动音量的地方。
//  - 控制中心/通知中心下拉、来电、App 切换器等会让 App 进入非活跃，此刻**临时解绑**：
//    调音量、拖控制中心滑块都正常工作（不然会被当成翻页、音量还会被拨回去），
//    回到活跃时以新音量重建基准。
//  - 活跃状态下，音量键不再调音量；关掉开关即恢复（保活、滑块、会话一起撤）。
//

import UIKit
import MediaPlayer
import AVFoundation

final class VolumeKeyPager: NSObject {

    enum Direction {
        case previous
        case next
    }

    /// 收到一次按键。方向已按映射规则翻译好。
    var onTurn: ((Direction) -> Void)?

    /// 开关。关闭时通知、滑块、音量视图、保活音频、会话全部撤销，系统音量键立刻回到原样。
    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    /// 音量键 → 翻页方向的映射，全工程只此一处。上键回退、下键前进。
    /// 想反过来，改这一行即可。
    private static func direction(volumeIncreased: Bool) -> Direction {
        volumeIncreased ? .previous : .next
    }

    // MARK: - State

    /// 检测通道标签，只用于诊断日志区分事件来自哪条通道。
    private enum Channel: String {
        case kvo = "KVO"
        case slider = "滑块"
    }

    private weak var host: UIView?
    private var volumeView: MPVolumeView?
    private var slider: UISlider?

    /// 要拨回的目标音量（按键前的系统音量）。
    private var referenceVolume: Float = 0

    /// 上一次已经当成按键处理过的音量值。两条通道的去重靠它。
    private var lastObservedVolume: Float = -1

    /// 正在程序化改音量（拨回 / 贴边内挪）——这期间的回调不是用户按键。
    private var isRestoringVolume = false

    /// 主通道：`AVAudioSession.outputVolume` 的 KVO。
    private var volumeObservation: NSKeyValueObservation?

    /// 静音保活播放器（见文件头「前提 B」）。
    private var silentPlayer: AVAudioPlayer?

    /// 音频中断（来电/闹钟）结束后把会话与保活接回来，否则功能会"悄悄停摆"。
    private var interruptionObserver: NSObjectProtocol?

    /// 回前台时重新接好会话/保活/滑块——切出去再切回来不该让功能失效。
    private var activeObserver: NSObjectProtocol?

    /// App 进入非活跃（控制中心/通知中心下拉、来电、App 切换器）时临时解绑。
    private var resignActiveObserver: NSObjectProtocol?

    /// 非活跃期间挂起检测：这期间的所有音量变化都是"用户在调音量"，不是翻页。
    private var isSuspended = false

    private var didActivateSession = false
    private var isRunning = false

    /// 滑块重试（惰性构建，见文件头）。
    private var sliderRetryWork: DispatchWorkItem?
    private var sliderRetryCount = 0
    private static let maxSliderRetries = 12   // 12 × 0.25s ≈ 3s

    /// "滑块缺失、音量拨不回"只在首次发生时记一条日志，避免每次翻页刷屏。
    private var didLogRestoreUnavailable = false

    // MARK: - 装配

    func attach(to view: UIView) {
        host = view
        if isEnabled { start() }
    }

    // MARK: - 启停

    private func start() {
        guard !isRunning, let host else { return }
        isRunning = true

        activateAudioSession()
        startSilentLoop()
        observeInterruptions()
        observeAppActivation()

        // 屏幕外，但确实在层级里（`isHidden` 会让它停止与系统音量同步）。
        let volumeView = WindowHookVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 100))
        volumeView.onMovedToWindow = { [weak self] in self?.adoptSliderIfPossible() }
        host.addSubview(volumeView)
        self.volumeView = volumeView

        // 基准音量先定下来（会话已激活，outputVolume 可靠）。
        // 滑块到位前做不了"贴边内挪"，那一刻的极值方向按键会漏一次，可接受。
        let current = AVAudioSession.sharedInstance().outputVolume
        referenceVolume = current
        lastObservedVolume = current

        // 检测通道与滑块解耦：一开始就装好，滑块找不到也照常检测。
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            self?.observe(volume: session.outputVolume, from: .kvo)
        }

        print("🔊[setup] 启动：会话=\(didActivateSession ? "OK" : "失败")"
              + "，保活=\(silentPlayer != nil ? "OK" : "失败")"
              + "，基准 \(fmt(current))，滑块=查找中")

        volumeView.layoutIfNeeded()
        adoptSliderIfPossible()
    }

    private func stop() {
        isRunning = false

        sliderRetryWork?.cancel()
        sliderRetryWork = nil
        sliderRetryCount = 0
        didLogRestoreUnavailable = false

        volumeObservation?.invalidate()
        volumeObservation = nil

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil

        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        activeObserver = nil

        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        resignActiveObserver = nil
        isSuspended = false

        slider?.removeTarget(self, action: nil, for: .valueChanged)
        slider = nil

        volumeView?.removeFromSuperview()
        volumeView = nil

        silentPlayer?.stop()
        silentPlayer = nil

        isRestoringVolume = false
        lastObservedVolume = -1
        deactivateAudioSession()
    }

    /// 阅读器被关闭/释放时也要把会话、保活、观察者全部撤掉，
    /// 否则功能会挂着继续吃掉音量键（哪怕书已经关了）。
    deinit { stop() }

    // MARK: - 滑块装配与重试

    /// 尝试装配 MPVolumeView 的内部滑块。找不到会自行排下一次重试，绝不放弃检测通道。
    private func adoptSliderIfPossible() {
        guard isRunning, slider == nil, let volumeView else { return }
        guard let found = Self.findSlider(in: volumeView) else {
            scheduleSliderRetry()
            return
        }
        configureSlider(found)
    }

    private func scheduleSliderRetry() {
        sliderRetryWork?.cancel()
        guard isRunning, sliderRetryCount < Self.maxSliderRetries else {
            if !didLogRestoreUnavailable {
                didLogRestoreUnavailable = true
                print("⚠️[setup] 多次重试仍未找到滑块：翻页检测照常（KVO 通道），"
                      + "但音量不会自动拨回；按键时会继续尝试补齐")
            }
            return
        }
        sliderRetryCount += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.adoptSliderIfPossible()
        }
        sliderRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func configureSlider(_ slider: UISlider) {
        guard self.slider == nil else { return }
        self.slider = slider

        // 贴边时往内挪一格，并把它作为基准。先更新基准再动手，
        // 这样 KVO 回传的"这次挪动"会被去重逻辑吃掉，不会误判成按键。
        let current = AVAudioSession.sharedInstance().outputVolume
        let base = Self.tolerantReference(current)
        referenceVolume = base
        lastObservedVolume = base
        if base != current { slider.setValue(base, animated: false) }

        slider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        print("🔊[setup] 滑块就绪（重试 \(sliderRetryCount) 次后）：基准 \(fmt(base))（原始 \(fmt(current))）")
    }

    /// 递归查找 MPVolumeView 内部的 UISlider（历史版本里它是 MPVolumeSlider，
    /// 也未必是直接子视图）。
    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let found = findSlider(in: subview) { return found }
        }
        return nil
    }

    /// 贴边时往内挪一格：音量 100% 时按上键没有任何数值变化，无从检测。
    private static func tolerantReference(_ volume: Float) -> Float {
        let step: Float = 1.0 / 16.0
        if volume >= 1.0 - 0.001 { return max(0, volume - step) }
        if volume <= 0.001 { return min(1, volume + step) }
        return volume
    }

    // MARK: - 两条检测通道

    @objc private func sliderValueChanged() {
        guard let slider else { return }
        observe(volume: slider.value, from: .slider)
    }

    /// 两条通道的唯一入口：去重 → 判向 → 拨回。
    private func observe(volume: Float, from channel: Channel) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.observe(volume: volume, from: channel) }
            return
        }
        // isSuspended：控制中心等系统 UI 打开期间解绑——那期间的音量变化都是
        // "用户在调音量"，既不能翻页，更不能把音量拨回去。
        guard isEnabled, !isSuspended, !isRestoringVolume else { return }
        // 同一次按键的第二条通道：值没再变过就不算第二次
        guard volume != lastObservedVolume else { return }
        guard volume != referenceVolume else { return }

        lastObservedVolume = volume
        let increased = volume > referenceVolume
        let target = referenceVolume      // 拨回目标：按键前的音量
        print("🔊[\(channel.rawValue)] 音量 \(fmt(target)) → \(fmt(volume))"
              + " → \(increased ? "上一页" : "下一页")")
        onTurn?(Self.direction(volumeIncreased: increased))

        // 滑块可能还没找到（惰性构建）。每次按键都是天然的补齐时机。
        if slider == nil { adoptSliderIfPossible() }

        guard let slider else {
            // 没有滑块 = 拨不回音量。宁可让这一次音量漂一格，也不能丢翻页。
            if !didLogRestoreUnavailable {
                didLogRestoreUnavailable = true
                print("⚠️ 滑块缺失：本次音量未拨回（检测与翻页不受影响）")
            }
            return
        }

        // 拨回原音量。必须异步：在回调里同步写回滑块，MPVolumeView
        // 有时来不及把这次写入落到实处，音量会一路漂走。
        isRestoringVolume = true
        DispatchQueue.main.async { [weak self] in
            slider.setValue(target, animated: false)
            guard let self else { return }
            self.referenceVolume = target
            self.lastObservedVolume = target
            self.isRestoringVolume = false
        }
    }

    // MARK: - 音频会话、静音保活、中断恢复

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback：把音量键路由到媒体音量；.mixWithOthers：不打断正在播放的音频
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            didActivateSession = true
        } catch {
            print("⚠️[setup] 音频会话激活失败 \(error)（音量键可能仍作用于铃声音量）")
            didActivateSession = false
        }
    }

    private func deactivateAudioSession() {
        guard didActivateSession else { return }
        didActivateSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 常驻静音循环（见文件头「前提 B」）：内容为全零 PCM，听不见；
    /// 只为让音频会话保持"正在播放"，音量键才会持续作用于媒体音量。
    private func startSilentLoop() {
        do {
            let player = try AVAudioPlayer(data: Self.makeSilentWAV())
            player.numberOfLoops = -1
            player.volume = 1
            _ = player.prepareToPlay()
            _ = player.play()
            silentPlayer = player
        } catch {
            print("⚠️[setup] 静音保活启动失败 \(error)")
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard isRunning,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .ended else { return }

        // 来电/闹钟结束后接回会话与保活。接不回也不会有害——最坏情况就是按键没反应，
        // 与接不接之前一样；但接回来就又活了。
        try? AVAudioSession.sharedInstance().setActive(true)
        _ = silentPlayer?.play()
        print("🔊[setup] 音频中断结束，会话与保活已恢复")
    }

    private func observeAppActivation() {
        // 控制中心/通知中心下拉、来电、App 切换器……都会让 App 进入非活跃。
        // 这期间必须临时解绑音量键翻页：用户在控制中心里拖音量滑块/按音量键
        // 就是为了调音量，不解绑就会被当成翻页、还会把音量拨回去。
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.suspendForSystemUI()
        }

        // 回到活跃：解绑结束。会话/保活/滑块可能被系统冻住要接回；
        // 用户可能刚在控制中心改过音量，要以新音量重建基准。
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAfterSystemUI()
        }
    }

    private func suspendForSystemUI() {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        print("🔊[setup] App 进入非活跃（控制中心等）：翻页已临时解绑，音量可正常调节")
    }

    private func resumeAfterSystemUI() {
        guard isRunning else { return }
        isSuspended = false

        // 会话/保活/滑块在后台可能被冻住，回来要接上，
        // 否则表现为「切出去看会儿别的，再回来音量键就不灵了」。
        if didActivateSession {
            try? AVAudioSession.sharedInstance().setActive(true)
        } else {
            activateAudioSession()
        }
        if silentPlayer == nil { startSilentLoop() } else { _ = silentPlayer?.play() }
        if slider == nil { adoptSliderIfPossible() }

        // 关键：以"现在"的音量为基准。用户可能刚在控制中心里调过音量，
        // 沿用旧基准会让下一次按键判向错误（拿新音量跟旧参照比）。
        rebaseline()
        print("🔊[setup] 回到活跃：解绑结束，基准重建为 \(fmt(referenceVolume))")
    }

    /// 把基准音量对齐到当前系统音量。贴边时仍按老规矩往内挪一格。
    private func rebaseline() {
        let current = AVAudioSession.sharedInstance().outputVolume
        let base = Self.tolerantReference(current)
        referenceVolume = base
        lastObservedVolume = base
        if base != current { slider?.setValue(base, animated: false) }
    }

    /// 内存生成 0.5s 静音 WAV（16-bit PCM 单声道 8kHz），无需任何音频资产文件。
    private static func makeSilentWAV(seconds: Double = 0.5, sampleRate: Int = 8000) -> Data {
        let sampleCount = Int(Double(sampleRate) * seconds)
        let dataSize = sampleCount * 2
        var d = Data(capacity: 44 + dataSize)
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        ascii("RIFF"); le32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        ascii("data"); le32(UInt32(dataSize)); d.append(Data(count: dataSize))
        return d
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
}

/// MPVolumeView 只在进入 window 之后才构建内部滑块。
/// 用它拿一次精准的"已进 window"回调，作为多重查找时机之一。
private final class WindowHookVolumeView: MPVolumeView {
    var onMovedToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }
}
