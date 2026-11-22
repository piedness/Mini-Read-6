//
//  通用设置.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - 系统设置

// 通用设置
struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isRegular: Bool { hSizeClass == .regular }

    /// 重置是不可撤销的破坏性操作，点一下就生效代价太高 —— 先要二次确认
    @State private var isConfirmingReset = false

    // MARK: 配置文件状态

    /// 磁盘上的全部配置文件（按保存时间倒序）。
    @State private var profiles: [SettingsProfile] = []
    /// 命名弹窗（alert 内嵌 TextField）与其中的草稿名。
    @State private var isNamingProfile = false
    @State private var newProfileName = ""
    /// 点击列表行 → 二次确认套用（非 nil 即弹确认框）。
    @State private var profilePendingApply: SettingsProfile?
    /// 导入成功 → 询问是否立即套用。
    @State private var importedPendingApply: SettingsProfile?
    @State private var isImportingProfile = false
    /// 导出：已编码好的文档 + 建议文件名，交给系统保存面板写入「文件」App。
    @State private var exportDocument: SettingsProfileDocument?
    @State private var exportFilename = "Vellium 配置"
    @State private var isExportingProfile = false
    /// 配置文件相关操作失败时的统一错误提示。
    @State private var profileErrorMessage = ""
    @State private var isShowingProfileError = false

    var body: some View {
        List {
            // 语言与地区
            Section {
                Picker("界面语言", selection: $settings.appLanguage) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                }
            } header: {
                Text("语言与地区")
            }

            Group {
                if !isRegular {
                    Section {
                        Toggle("触觉反馈", isOn: hapticFeedbackBinding)
                    } header: {
                        Text("交互")
                    }
                }
            }

            // 配置文件：保存 / 套用 / 导入 / 删除
            profileSection

            // 重置
            Section {
                Button("恢复默认设置") {
                    isConfirmingReset = true
                }
                .foregroundStyle(.red)
                .accessibilityLabel("恢复默认设置")
                .accessibilityHint("将所有设置还原为初始值，书籍与阅读进度不会受影响")
            } header: {
                Text("重置")
            }
        }
        .modifier(CustomListModifier(title: "通用设置"))
        .onAppear {
            profiles = SettingsProfileStore.all()
            #if DEBUG
            // 开发期守卫：AppSettings 新增属性而映射表漏行时，控制台点名。
            SettingsProfileSchema.warnIfFieldsOutOfSync()
            #endif
        }
        .alert("恢复默认设置？", isPresented: $isConfirmingReset) {
            Button("取消", role: .cancel) { }
            Button("恢复默认", role: .destructive) {
                performReset()
            }
        } message: {
            Text("所有设置项将还原为初始值。你的书籍、阅读进度、书签和高亮不会受影响。")
        }
        .alert("保存为配置文件", isPresented: $isNamingProfile) {
            TextField("配置名称", text: $newProfileName)
            Button("取消", role: .cancel) { }
            Button("保存") {
                performSaveProfile()
            }
        } message: {
            Text("当前的全部设置会保存为一个配置文件，之后可随时套用。")
        }
        .alert("套用配置文件？", isPresented: isConfirmingApply, presenting: profilePendingApply) { profile in
            Button("取消", role: .cancel) { }
            Button("套用") {
                performApply(profile)
            }
        } message: { profile in
            Text("当前设置将替换为「\(profile.name)」保存时的状态。书籍、阅读进度、书签与高亮不受影响。")
        }
        .alert("已导入配置文件", isPresented: isConfirmingImportedApply, presenting: importedPendingApply) { profile in
            Button("稍后", role: .cancel) { }
            Button("立即套用") {
                performApply(profile)
            }
        } message: { profile in
            Text("「\(profile.name)」已加入列表。是否立即套用到当前设置？")
        }
        .alert("操作失败", isPresented: $isShowingProfileError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(profileErrorMessage)
        }
        .fileExporter(
            isPresented: $isExportingProfile,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            handleProfileExport(result)
        }
        .fileImporter(
            isPresented: $isImportingProfile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleProfileImport(result)
        }
    }

    // MARK: - 配置文件区块

    @ViewBuilder
    private var profileSection: some View {
        Section {
            ForEach(profiles) { profile in
                profileRow(profile)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteProfile(profile)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }

            Button {
                newProfileName = defaultProfileName()
                isNamingProfile = true
            } label: {
                Label("保存当前设置为配置文件", systemImage: "plus")
            }
            .accessibilityHint("把当前的所有设置保存为一个配置文件")

            Button {
                isImportingProfile = true
            } label: {
                Label("导入配置文件", systemImage: "square.and.arrow.down")
            }
            .accessibilityHint("从「文件」应用选择之前保存或他人分享的配置文件")
        } header: {
            Text("配置文件")
        }
    }

    /// 一行配置文件：名称 + 「N 项设置 · 日期」。整行可点，点了先出确认框。
    ///
    /// 三个入口都通到同一批行为上：轻点套用、**右滑导出**、左滑删除，
    /// 长按还有菜单兜底（滑动操作对 VoiceOver 不可达，这里补了无障碍自定义动作）。
    private func profileRow(_ profile: SettingsProfile) -> some View {
        Button {
            profilePendingApply = profile
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    Text(profileSubtitle(profile))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginExport(profile)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                beginExport(profile)
            } label: {
                Label("导出到「文件」", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deleteProfile(profile)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name)，\(profileSubtitle(profile))")
        .accessibilityHint("套用该配置文件")
        .accessibilityAction(named: "导出到「文件」") { beginExport(profile) }
        .accessibilityAction(named: "删除") { deleteProfile(profile) }
    }

    private func profileSubtitle(_ profile: SettingsProfile) -> String {
        let date = profile.createdAt.formatted(date: .abbreviated, time: .omitted)
        return "\(profile.values.count) 项设置 · \(date)"
    }

    /// 「套用确认」的布尔桥接：待确认项非空即弹框；关框时把待确认项清空
    /// （点「套用」时动作闭包拿到的是值拷贝，不受清空影响）。
    private var isConfirmingApply: Binding<Bool> {
        Binding(
            get: { profilePendingApply != nil },
            set: { if !$0 { profilePendingApply = nil } }
        )
    }

    private var isConfirmingImportedApply: Binding<Bool> {
        Binding(
            get: { importedPendingApply != nil },
            set: { if !$0 { importedPendingApply = nil } }
        )
    }

    // MARK: - 配置文件行为

    /// 命名弹窗的预填值：从「配置 N」里取第一个未占用的 N。
    private func defaultProfileName() -> String {
        let existing = Set(profiles.map(\.name))
        var index = profiles.count + 1
        while existing.contains("配置 \(index)") { index += 1 }
        return "配置 \(index)"
    }

    /// 保存当前设置为一个新的配置文件。
    ///
    /// 只写盘、不动当前设置：列表出现新行即成果展示，触觉取与排序切换同档的 `.light`。
    private func performSaveProfile() {
        do {
            try SettingsProfileStore.create(from: settings, name: newProfileName)
            profiles = SettingsProfileStore.all()
            triggerHaptic(.light)
        } catch {
            triggerNotificationHaptic(.error)
            profileErrorMessage = "保存配置文件失败：\(error.localizedDescription)"
            isShowingProfileError = true
        }
    }

    /// 套用一个配置文件。
    ///
    /// ⚠️ 后半段的顺序与 `performReset()` 完全同构，理由同出一源：
    /// ① 写值 → 落盘 → 广播（阅读器据广播重排，音量键开关等一并重挂）；
    /// ② 震动按**套用前**的偏好决定——此刻闸门还停在旧值上，
    ///    原本关着触觉反馈的用户不该因为"套用了一个开着的配置"而突然挨一下；
    /// ③ 最后才把闸门对齐到套用后的设置（配置把 `hapticFeedback` 改成什么就是什么）。
    private func performApply(_ profile: SettingsProfile) {
        SettingsProfileStore.apply(profile, to: settings)

        try? modelContext.save()
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)

        triggerHaptic(.medium)
        Haptics.sync(with: settings)
    }

    /// 删除一个配置文件。
    ///
    /// 删的是本机偏好快照（不触及书籍与阅读数据），但仍是不可撤销的删除，
    /// 触觉沿用删除书籍同档的 `.medium`。
    private func deleteProfile(_ profile: SettingsProfile) {
        do {
            try SettingsProfileStore.delete(profile.id)
            profiles = SettingsProfileStore.all()
            triggerHaptic(.medium)
        } catch {
            triggerNotificationHaptic(.error)
            profileErrorMessage = "删除配置文件失败：\(error.localizedDescription)"
            isShowingProfileError = true
        }
    }

    /// 从「文件」导入一个配置文件。
    ///
    /// 失败一律**不静默**：用户看到明确的错误说明，而不是"点了没反应"。
    ///
    /// - Note: `fileImporter` 的回调恒为 `Result<[URL], Error>`（即使单选），
    ///   与字体导入同一形态，取第一个元素即可。
    private func handleProfileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let imported = try SettingsProfileStore.importProfile(from: url)
                profiles = SettingsProfileStore.all()
                // 与导入书籍同语义：一次完成的结果反馈。
                triggerNotificationHaptic(.success)
                importedPendingApply = imported
            } catch {
                triggerNotificationHaptic(.error)
                profileErrorMessage = error.localizedDescription
                isShowingProfileError = true
            }
        case .failure(let error):
            // 取消选择也会回调到这里，用户主动取消不是失败，不弹错误。
            guard !isUserCancelled(error) else { return }

            triggerNotificationHaptic(.error)
            profileErrorMessage = "导入失败：\(error.localizedDescription)"
            isShowingProfileError = true
        }
    }

    /// 把一个配置文件导出到「文件」App。
    ///
    /// 编码放在点按这一刻完成（配置文件以 KB 计，同步 I/O 无感知）：一旦编码失败
    /// 立刻给出反馈，而不是"保存面板打开了却写不出内容"。成功路径交给系统面板，
    /// 用户可在其中选目录、改文件名——本 App 不干预，也就不会出现自建路径写不进去的问题。
    private func beginExport(_ profile: SettingsProfile) {
        do {
            exportDocument = SettingsProfileDocument(data: try SettingsProfileStore.exportData(for: profile))
            exportFilename = SettingsProfileStore.exportFileName(for: profile)
            isExportingProfile = true
        } catch {
            triggerNotificationHaptic(.error)
            profileErrorMessage = "导出配置文件失败：\(error.localizedDescription)"
            isShowingProfileError = true
        }
    }

    /// 系统保存面板的回调：落盘成功给一次完成反馈；取消不算失败；其余弹错误。
    private func handleProfileExport(_ result: Result<URL, Error>) {
        // 关面板后顺手释放文档（几 KB，但没必要常驻）。
        exportDocument = nil
        switch result {
        case .success:
            triggerNotificationHaptic(.success)
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            triggerNotificationHaptic(.error)
            profileErrorMessage = "导出失败：\(error.localizedDescription)"
            isShowingProfileError = true
        }
    }

    /// 用户主动取消不是失败：`fileImporter` / `fileExporter` 的取消都会以
    /// `CocoaError.userCancelled` 或 `URLError.cancelled` 回调到完成闭包。
    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }

    /// 触觉反馈开关的绑定。
    ///
    /// **刻意不用 `$settings.hapticFeedback` + `.onChange`**：`onChange` 对
    /// 程序化改动一样会触发——`performReset()` 里 `resetToDefaults()` 会把
    /// `hapticFeedback` 写回 `true`，于是"用户先关掉开关、再点恢复默认"
    /// 会同时走上两条放电路径，连震两下。
    ///
    /// 自定义 binding 的 `set` **只在用户真正拨动开关时**执行，
    /// 程序化改动不经过它，重复触发从根上不存在。
    private var hapticFeedbackBinding: Binding<Bool> {
        Binding(
            get: { settings.hapticFeedback },
            set: { newValue in
                settings.hapticFeedback = newValue
                // 先对齐总闸，再放电：关掉开关时闸门刚变 false，
                // 紧接着的 `triggerHaptic` 会被它自己挡下——
                // "关掉之后不该再震"是免费得到的，这里不必再写一次判断。
                Haptics.sync(with: settings)
                // 触觉反馈不参与排版，**不广播** `.appSettingsDidChange`，
                // 否则阅读器会为一次与排版无关的改动白重排一遍。
                try? modelContext.save()
                triggerHaptic(.light)
            }
        )
    }

    /// 「恢复默认设置」的实际执行体。
    ///
    /// ⚠️ **最后两步的顺序不可调换**，理由见各自的注释。
    private func performReset() {
        // 每项都用 `withAnimation` 包住不合算：这里是一次性批量写入，
        // 让外层 @Query 驱动一次 diff 即可，逐项动画反而会抖。
        settings.resetToDefaults()

        // 合成一次落盘 + 一次重排广播。阅读器内部已有 0.35s 防抖，
        // 这里不需要再做合并（MainViewController.settingsReloadWork）。
        try? modelContext.save()
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)

        // ① 确认震动按**重置前**的偏好决定：
        //    用户本来关着触觉反馈，不该因为点了一次「恢复默认」就突然震一下。
        //    此刻闸门还停在旧值上（② 尚未执行），所以这一次会自然被挡下。
        triggerHaptic(.medium)

        // ② 最后才把闸门对齐到新设置。重置会把 `hapticFeedback` 写回 `true`，
        //    所以必须放在震动之后——否则原本关着开关的用户也会挨这一下。
        Haptics.sync(with: settings)
    }
}
