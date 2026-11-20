import SwiftUI
import SwiftData

// MARK: - 路由枚举
enum SettingsRoute: Hashable, CaseIterable {
    // 阅读体验
    case typography
    case themeColor
    case pageTurning
    case readingAssist
    // 书库管理
    case libraryView
    case importFormat
    case storage
    // 笔记与标注
    case highlight
    case noteSystem
    case exportShare
    // 隐私与安全
    case privacySecurity
    // 系统设置
    case customize
    case general
    case performance
    case about
}

// MARK: - 菜单数据模型与分组
struct SettingsItem: Identifiable, Hashable {
    var id: SettingsRoute { route }
    let route: SettingsRoute
    let label: String
    let icon: String
    let iconColor: Color
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case system = "系统设置"
    case reading = "阅读体验"
    case library = "书库管理"
    case notes = "笔记与标注"
    case privacy = "隐私与安全"
    case other = "其他"
    
    var id: String { rawValue }
    
    var items: [SettingsItem] {
        switch self {
        case .system:
            return [
                SettingsItem(route: .general,     label: "通用设置",   icon: "gearshape.fill",        iconColor: .gray),
                SettingsItem(route: .customize,   label: "个性化",     icon: "heart.text.square.fill", iconColor: .pink)
            ]
        case .reading:
            return [
                SettingsItem(route: .themeColor,   label: "主题与色彩", icon: "paintbrush.fill",      iconColor: .purple),
                SettingsItem(route: .typography,   label: "文字排版",   icon: "textformat",           iconColor: .blue),
                SettingsItem(route: .pageTurning,  label: "翻页与交互", icon: "hand.tap.fill",        iconColor: .orange),
                SettingsItem(route: .readingAssist, label: "辅助功能",  icon: "eye.fill",             iconColor: .green)
            ]
        case .library:
            return [
                SettingsItem(route: .libraryView,  label: "视图与组织", icon: "square.grid.2x2.fill", iconColor: .indigo),
                SettingsItem(route: .importFormat, label: "导入与格式", icon: "arrow.down.doc.fill",  iconColor: .teal),
                SettingsItem(route: .storage,      label: "存储管理",   icon: "internaldrive.fill",   iconColor: .gray)
            ]
        case .notes:
            return [
                SettingsItem(route: .highlight,   label: "高亮与标注", icon: "highlighter",          iconColor: .yellow),
                SettingsItem(route: .noteSystem,  label: "笔记系统",   icon: "note.text",            iconColor: .orange),
                SettingsItem(route: .exportShare, label: "导出与分享", icon: "square.and.arrow.up.fill", iconColor: .blue)
            ]
        case .privacy:
            return [
                SettingsItem(route: .privacySecurity, label: "访问控制与隐私", icon: "lock.fill", iconColor: .blue)
            ]
        case .other:
            return [
                SettingsItem(route: .performance, label: "性能优化",   icon: "speedometer",      iconColor: .mint),
                SettingsItem(route: .about,       label: "关于与帮助", icon: "info.circle.fill", iconColor: .gray)
            ]
        }
    }
}

// MARK: - Main Settings View (Responsive Split Layout)
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query private var settings: [AppSettings]
    @State private var showProfile: Bool = false
    @State private var selectedRoute: SettingsRoute? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var detailNavigationID = UUID()
    @State private var detailEntranceStep = 0
    @State private var hasPerformedInitialEntrance = false

    /// 统一走 `appSettings()`：设置页必须写入阅读器读的那一条记录，
    /// 否则改了字体书里不会变（见 ModelContext.appSettings 的说明）。
    /// 这里保留 `@Query` 只是为了设置变化时触发本视图刷新。
    private var appSettings: AppSettings {
        modelContext.appSettings()
    }

    private var isRegular: Bool { hSizeClass == .regular }

    var body: some View {
        Group {
            if isRegular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showProfile) {
            ProfileView(settings: appSettings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear(perform: handleOnAppear)
        .onChange(of: hSizeClass) { _, _ in
            handleSizeClassChange()
        }
        .onChange(of: selectedRoute) { _, _ in
            handleCompactSelectionChange()
        }
    }

    private var iPadLayout: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            // 响应式宽度调整：窄屏按比例分栏，宽屏固定 Sidebar 宽度
            let sidebarWidth: CGFloat = totalWidth < 680 ? max(240, totalWidth * 0.38) : 320
            
            HStack(spacing: 0) {
                // MARK: - 左侧一级菜单栏
                SidebarView(
                    selectedRoute: $selectedRoute,
                    showProfile: $showProfile,
                    onSelect: { item in
                        select(item)
                    }
                )
                .frame(width: sidebarWidth)
                .background(.clear)

                // MARK: - 中央分割线
                Divider()
                    .ignoresSafeArea(.keyboard, edges: .vertical)

                // MARK: - 右侧二级菜单/详情页
                DetailContainerView(
                    selectedRoute: selectedRoute,
                    navigationID: detailNavigationID,
                    entranceStep: detailEntranceStep,
                    appSettings: appSettings,
                    destinationBuilder: destination(for:)
                )
                .frame(maxWidth: .infinity)
                .background(.clear)
            }
            
        }
    }

    private var iPhoneLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            iPhoneSidebar
        } detail: {
            DetailContainerView(
                selectedRoute: selectedRoute,
                navigationID: detailNavigationID,
                entranceStep: detailEntranceStep,
                appSettings: appSettings,
                destinationBuilder: destination(for:)
            )
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var iPhoneSidebar: some View {
        List(selection: $selectedRoute) {
            Section {
                Button {
                    showProfile = true
                } label: {
                    AccountRow()
                }
                .buttonStyle(.plain)
            }

            ForEach(SettingsGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.items) { item in
                        SettingsListRow(item: item)
                            .tag(item.route)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Setting")
        .navigationBarTitleDisplayMode(.large)
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
//        .toolbar {
//            // 1. 导航栏右侧组
//            ToolbarItemGroup(placement: .navigationBarTrailing) {
//                Button(action: { }) {
//                    Image(systemName: "square.and.arrow.up")
//                }
//                Button(action: { }) {
//                    Image(systemName: "ellipsis")
//                }
//            }
//        }
    }

    private func handleOnAppear() {
        applyDefaultSelectionIfNeeded()

        guard isRegular else { return }
        guard !hasPerformedInitialEntrance else { return }
        hasPerformedInitialEntrance = true
        startDetailEntrance()
    }

    private func handleSizeClassChange() {
        if isRegular {
            applyDefaultSelectionIfNeeded()
            guard !hasPerformedInitialEntrance else { return }
            hasPerformedInitialEntrance = true
            startDetailEntrance()
        } else {
            // iPhone 进入设置时应停在侧边栏，不应自动选中并 push 详情。
            selectedRoute = nil
        }
    }

    private func applyDefaultSelectionIfNeeded() {
        guard isRegular, selectedRoute == nil else { return }
        selectedRoute = .general
    }

    private func handleCompactSelectionChange() {
        guard !isRegular, selectedRoute != nil else { return }

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            detailNavigationID = UUID()
            detailEntranceStep = 0
        }

        startDetailEntrance()
    }

    private func select(_ item: SettingsItem) {
        // 强制替换 NavigationStack，确保从旧菜单的二级页面退出。
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            detailNavigationID = UUID()
            detailEntranceStep = 0
        }

        withAnimation(.easeOut(duration: 0.16)) {
            selectedRoute = item.route
        }

        startDetailEntrance()
    }

    private func startDetailEntrance() {
        guard !reduceMotion else {
            detailEntranceStep = 2
            return
        }

        let spring = Animation.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0)
        withAnimation(spring.delay(0.02)) {
            detailEntranceStep = 1
        }
        withAnimation(spring.delay(0.08)) {
            detailEntranceStep = 2
        }
    }

    // MARK: - 路由 → 页面映射
    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .typography:      TypographySettingsView(settings: appSettings)
        case .themeColor:      ThemeColorSettingsView(settings: appSettings)
        case .pageTurning:     PageTurningSettingsView(settings: appSettings)
        case .readingAssist:   ReadingAssistView(settings: appSettings)
        case .libraryView:     LibraryViewSettingsView(settings: appSettings)
        case .importFormat:    ImportFormatSettingsView(settings: appSettings)
        case .storage:         StorageSettingsView(settings: appSettings)
        case .highlight:       HighlightSettingsView(settings: appSettings)
        case .noteSystem:      NoteSystemSettingsView(settings: appSettings)
        case .exportShare:     ExportShareSettingsView(settings: appSettings)
        case .privacySecurity: PrivacySecuritySettingsView(settings: appSettings)
        case .general:         GeneralSettingsView(settings: appSettings)
        case .performance:     PerformanceSettingsView(settings: appSettings)
        case .about:           AboutView()
        case .customize:       CustomizeSettingsView(settings: appSettings)
        }
    }
}

// MARK: - 左侧一级菜单视图 (SidebarView)
private struct SidebarView: View {
    @Binding var selectedRoute: SettingsRoute?
    @Binding var showProfile: Bool
    let onSelect: (SettingsItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部大标题栏
            HStack {
                Text("Setting")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // 账户信息卡片
                    Button {
                        showProfile.toggle()
                    } label: {
                        AccountRow()
                    }
                    .buttonStyle(SidebarButtonStyle())
                    .padding(.horizontal, 12)

                    // 各个分组菜单
                    ForEach(SettingsGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                            
                            VStack(spacing: 2) {
                                ForEach(group.items) { item in
                                    SidebarRow(
                                        item: item,
                                        isSelected: selectedRoute == item.route
                                    ) {
                                        onSelect(item)
                                    }
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemGroupedBackground))
                            )
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - 左侧菜单行组件 (SidebarRow)
private struct SidebarRow: View {
    let item: SettingsItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标 Badge
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(item.iconColor.gradient)
                        .frame(width: 28, height: 28)

                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text(item.label)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iPhone 侧栏列表行
private struct SettingsListRow: View {
    let item: SettingsItem

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                .fill(item.iconColor.gradient)
                .frame(width: iconSize, height: iconSize)
                .overlay {
                    Image(systemName: item.icon)
                        .font(.system(size: iconSize * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                }

            Text(item.label)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
    }
}

// MARK: - 右侧二级菜单/详情容器视图 (DetailContainerView)
private struct DetailContainerView<Content: View>: View {
    let selectedRoute: SettingsRoute?
    let navigationID: UUID
    let entranceStep: Int
    let appSettings: AppSettings
    let destinationBuilder: (SettingsRoute) -> Content

    var body: some View {
        NavigationStack {
            ZStack {
                if let route = selectedRoute {
                    destinationBuilder(route)
                        .transition(.opacity)
                } else {
                    ContentUnavailableView(
                        "请选择设置项",
                        systemImage: "book.pages",
                        description: Text("在左侧菜单中选择一项以调整阅读器与书库设置。")
                    )
                    .transition(.opacity)
                }
            }
            .modifier(DetailEntranceModifier(step: entranceStep))
        }
        .id(navigationID)
    }
}

private struct DetailEntranceModifier: ViewModifier {
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(step > 0 ? 1 : 0)
                .offset(y: step > 1 ? 0 : 12)
        }
    }
}

// MARK: - 按压效果 ButtonStyle
private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Account Card
struct AccountRow: View {
    @ObservedObject private var avatarStore = AvatarImageStore.shared

    var body: some View {
        HStack(spacing: 12) {
            // 头像
            ZStack {
                if let img = avatarStore.avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                        .frame(width: 48, height: 48)
                } else {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                AngularGradient(
                                    colors: [.blue, .blue.opacity(0.2), .blue, .blue.opacity(0.1), .blue],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                            )
                            .frame(width: 50, height: 50)

                        Circle()
                            .fill(Color(.tertiarySystemGroupedBackground))
                            .frame(width: 44, height: 44)

                        Image(systemName: "applelogo")
                            .font(.system(size: 20))
                            .foregroundColor(.primary)
                    }
                }
            }

            // 文字信息
            VStack(alignment: .leading, spacing: 2) {
                Text("Local account")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Press to access reading data")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }
}
