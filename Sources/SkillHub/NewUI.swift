import SwiftUI

// MARK: - 主界面：原生 macOS 三栏布局

struct NewContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showCommandPalette = false
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            NativeSidebar()
        } content: {
            ContentView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            DetailContainer()
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索 skills")
        .onChange(of: searchText) { _, newValue in
            state.smartSearchQuery = newValue
            state.performSmartSearch()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.isBusy || state.aiAnalyzing || state.updateChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                // 图标下方显示中文标签（macOS 工具栏默认只显示图标）
                Group {
                    Button { showCommandPalette = true } label: {
                        Label("命令面板", systemImage: "command")
                    }
                    .keyboardShortcut("k")
                    Button { state.showMarketplace = true } label: {
                        Label("市场", systemImage: "storefront")
                    }
                    Button { state.showInstall = true } label: {
                        Label("安装", systemImage: "plus")
                    }
                    Button { state.refresh(force: true) } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                    Divider()
                    Menu {
                        Button("导出技能清单…") { state.exportManifest() }
                        Button("导入技能清单…") { state.importManifest() }
                    } label: {
                        Label("清单", systemImage: "shippingbox")
                    }
                    Button { state.checkForUpdates() } label: {
                        Label("更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(state.updateChecking)
                    Button { state.showAIAnalysis = true } label: {
                        Label("AI 分析", systemImage: "brain")
                    }
                    Button { state.showManager = true } label: {
                        Label("管家", systemImage: "wand.and.stars")
                    }
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .onAppear { state.refreshManager() }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteSheet()
        }
        .sheet(isPresented: $state.showManager) {
            ManagerSheet()
        }
        .sheet(isPresented: $state.showAIAnalysis) {
            AIAnalysisSheet()
        }
        .sheet(isPresented: $state.showDoctor) {
            DoctorSheet()
        }
        .sheet(isPresented: $state.showInstall) {
            InstallSheet()
        }
        .sheet(isPresented: $state.showMarketplace) {
            MarketplaceView(onInstall: { source in
                await state.installFromMarketplace(source: source)
            })
            .frame(minWidth: 680, minHeight: 520)
        }
        // 统一的操作反馈横幅：通知自动消失，错误需手动关闭
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let error = state.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.callout)
                            .lineLimit(2)
                        Spacer()
                        Button("关闭") { state.lastError = nil }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                }
                if let notice = state.lastNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: state.lastNotice)
            .animation(.easeInOut(duration: 0.2), value: state.lastError)
        }
    }
}

// MARK: - 原生侧栏

struct NativeSidebar: View {
    @EnvironmentObject var state: AppState
    @State private var showAddAgentSheet = false
    @State private var isCategoryExpanded = true
    @State private var isAuthorExpanded = false
    @State private var isAgentExpanded = false
    @State private var isPresetExpanded = true
    @State private var showNewPresetAlert = false
    @State private var newPresetName = ""
    @State private var renamingPreset: SkillPreset? = nil
    @State private var renamePresetName = ""
    @State private var deletingPreset: SkillPreset? = nil
    /// 侧栏是否隐藏 0 个 skill 的空平台（默认隐藏，避免一堆没装 skills 的平台刷屏）
    @AppStorage("hideEmptyPlatforms") private var hideEmptyPlatforms = true

    var body: some View {
        List(selection: sidebarSelection) {
            Section("快速操作") {
                Label {
                    HStack {
                        Text("收藏夹")
                        Spacer()
                        Text("\(state.favorites.count)")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                } icon: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                .tag(SidebarTag.favorites)

                Label {
                    HStack {
                        Text("最近使用")
                        Spacer()
                        Text("\(state.usageInfo.filter { $0.category == .active }.count)")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                } icon: {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.blue)
                }
                .tag(SidebarTag.recent)
            }

            DisclosureGroup("场景", isExpanded: $isPresetExpanded) {
                if state.presets.isEmpty {
                    Text("按工作场景一键启用/停用 skills，点击下方「新建场景」开始")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.presets) { preset in
                    Label {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text("\(preset.skillNames.count)")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                    } icon: {
                        Image(systemName: "rectangle.3.group.fill")
                            .foregroundStyle(.teal)
                    }
                    .tag(SidebarTag.preset(preset.id))
                    .contextMenu {
                        Button("重命名…") {
                            renamingPreset = preset
                            renamePresetName = preset.name
                        }
                        Button("删除", role: .destructive) {
                            deletingPreset = preset
                        }
                    }
                }

                Button {
                    showNewPresetAlert = true
                } label: {
                    Label("新建场景", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if !state.categorizedSkills.isEmpty {
                DisclosureGroup("分类", isExpanded: $isCategoryExpanded) {
                    ForEach(state.categorizedSkills) { group in
                        Label {
                            HStack {
                                Text(group.category.rawValue)
                                Spacer()
                                Text("\(group.skills.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.callout.monospacedDigit())
                            }
                        } icon: {
                            Image(systemName: group.category.icon)
                                .foregroundStyle(categoryColor(for: group.category))
                        }
                        .tag(SidebarTag.category(group.category.rawValue))
                    }
                }
            }

            if !state.authorGroups.isEmpty {
                DisclosureGroup("作者", isExpanded: $isAuthorExpanded) {
                    ForEach(state.authorGroups) { group in
                        Label {
                            HStack {
                                Text(group.displayName)
                                Spacer()
                                Text("\(group.skills.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.callout.monospacedDigit())
                            }
                        } icon: {
                            Image(systemName: "person.circle")
                                .foregroundStyle(.indigo)
                        }
                        .tag(SidebarTag.author(group.author))
                    }
                }
            }

            DisclosureGroup("Agent 平台", isExpanded: $isAgentExpanded) {
                // 本体库始终显示；其余平台在开启「隐藏空平台」时只显示有 skills 的
                let visibleTargets = state.targets.filter(\.exists).filter { target in
                    !hideEmptyPlatforms
                        || target.id == AgentTarget.canonicalID
                        || state.skills.contains { $0.presence[target.id] != nil }
                }
                ForEach(visibleTargets) { target in
                    let count = state.skills.filter { $0.presence[target.id] != nil }.count
                    Label {
                        HStack {
                            Text(target.displayName)
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                    } icon: {
                        Image(systemName: agentIcon(target.id))
                            .foregroundStyle(agentColor(target.id))
                    }
                    .tag(SidebarTag.agent(target.id))
                }

                Button {
                    showAddAgentSheet = true
                } label: {
                    Label("添加平台", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }

                Button {
                    hideEmptyPlatforms.toggle()
                } label: {
                    Label(
                        hideEmptyPlatforms ? "显示空平台" : "隐藏空平台",
                        systemImage: hideEmptyPlatforms ? "eye" : "eye.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SkillHub")
        .sheet(isPresented: $showAddAgentSheet) {
            AddAgentSheet()
        }
        .alert("新建场景", isPresented: $showNewPresetAlert) {
            TextField("场景名称，如：前端开发", text: $newPresetName)
            Button("创建") {
                state.createPreset(name: newPresetName)
                newPresetName = ""
            }
            Button("取消", role: .cancel) { newPresetName = "" }
        }
        .alert("重命名场景", isPresented: Binding(
            get: { renamingPreset != nil },
            set: { if !$0 { renamingPreset = nil } }
        )) {
            TextField("场景名称", text: $renamePresetName)
            Button("重命名") {
                if let preset = renamingPreset {
                    state.renamePreset(preset, name: renamePresetName)
                }
                renamingPreset = nil
            }
            Button("取消", role: .cancel) { renamingPreset = nil }
        }
        .alert("删除场景", isPresented: Binding(
            get: { deletingPreset != nil },
            set: { if !$0 { deletingPreset = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let preset = deletingPreset {
                    state.deletePreset(preset)
                }
                deletingPreset = nil
            }
            Button("取消", role: .cancel) { deletingPreset = nil }
        } message: {
            Text("确定删除场景「\(deletingPreset?.name ?? "")」？只会移除场景本身，不会删除任何 skill。")
        }
    }

    private var sidebarSelection: Binding<SidebarTag?> {
        Binding(
            get: {
                if let presetID = state.selectedPresetID {
                    return .preset(presetID)
                }
                if let filter = state.selectedQuickFilter {
                    return filter == .favorites ? .favorites : .recent
                }
                if let category = state.selectedCategory {
                    return .category(category.rawValue)
                }
                if let author = state.selectedAuthor {
                    return .author(author)
                }
                if let agentId = state.selectedAgentFilter {
                    return .agent(agentId)
                }
                return nil
            },
            set: { tag in
                state.selectedQuickFilter = nil
                state.selectedCategory = nil
                state.selectedAuthor = nil
                state.selectedAgentFilter = nil
                state.selectedPresetID = nil
                state.selectedSkillForDetail = nil
                state.selectedSkillID = nil
                state.smartSearchQuery = ""

                guard let tag else { return }
                switch tag {
                case .favorites:
                    state.selectedQuickFilter = .favorites
                case .recent:
                    state.selectedQuickFilter = .recent
                case .category(let name):
                    state.selectedCategory = SkillManager.SkillCategory(rawValue: name)
                case .author(let author):
                    state.selectedAuthor = author
                case .agent(let id):
                    state.selectedAgentFilter = id
                case .preset(let id):
                    state.selectedPresetID = id
                }
            }
        )
    }

    private enum SidebarTag: Hashable {
        case favorites
        case recent
        case category(String)
        case author(String)
        case agent(String)
        case preset(UUID)
    }

    private func categoryColor(for category: SkillManager.SkillCategory) -> Color {
        switch category {
        case .writing: return .blue
        case .coding: return .purple
        case .data: return .green
        case .communication: return .orange
        case .creative: return .pink
        case .other: return .gray
        }
    }

    private func agentIcon(_ id: String) -> String {
        switch id {
        case "agents": return "shippingbox"
        case "claude": return "brain"
        case "cursor": return "cursorarrow"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "gearshape"
        }
    }

    private func agentColor(_ id: String) -> Color {
        .accentColor
    }
}

// MARK: - 中间内容区

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if !state.smartSearchQuery.isEmpty {
                SearchResultsList()
            } else if let presetID = state.selectedPresetID {
                PresetList(presetID: presetID)
            } else if let category = state.selectedCategory {
                CategoryList(category: category)
            } else if let author = state.selectedAuthor {
                AuthorFilterList(author: author)
            } else if let quickFilter = state.selectedQuickFilter {
                QuickFilterList(filter: quickFilter)
            } else if let agentId = state.selectedAgentFilter {
                AgentFilterList(agentId: agentId)
            } else {
                HomeList()
            }
        }
    }
}

// MARK: - 技能列表

struct SkillListItems: View {
    let skills: [Skill]
    @EnvironmentObject var state: AppState

    var body: some View {
        // 绑定 selection：点击的行有选中高亮，清楚标识当前详情页展示的是哪个 skill
        List(skills, selection: $state.selectedSkillID) { skill in
            SkillRow(skill: skill)
                .tag(skill.id)
                .onTapGesture {
                    state.selectedSkillForDetail = skill
                    state.selectedSkillID = skill.id
                }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
    }
}

struct SkillRow: View {
    let skill: Skill
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(skill.name)
                    .font(.headline)
                if let v = skill.version {
                    Text("v\(v)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !skill.author.isEmpty {
                    Text(skill.author)
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }
                Spacer()
                if skill.hasUpdate {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .help("有新版本")
                }
                if state.isFavorite(skill) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }

            if !skill.descriptionText.isEmpty {
                Text(skill.descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                ForEach(skill.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(skill.sizeDisplay)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 搜索结果列表

struct SearchResultsList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.searchResults.isEmpty {
                ContentUnavailableView(
                    "没有找到匹配的 skills",
                    systemImage: "magnifyingglass",
                    description: Text("尝试其他关键词")
                )
            } else {
                List(state.searchResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.skill.name)
                                .font(.headline)
                            Text(result.matchReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(result.score * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if !result.skill.descriptionText.isEmpty {
                            Text(result.skill.descriptionText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .onTapGesture {
                        state.selectedSkillForDetail = result.skill
                        state.selectedSkillID = result.skill.id
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - 分类列表

struct CategoryList: View {
    let category: SkillManager.SkillCategory
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let group = state.categorizedSkills.first(where: { $0.category == category }) {
                SkillListItems(skills: group.skills)
            } else {
                ContentUnavailableView(
                    "该分类下没有 skills",
                    systemImage: category.icon,
                    description: Text("尝试切换到其他分类")
                )
            }
        }
        .navigationTitle(category.rawValue)
    }
}

// MARK: - 快捷过滤列表

struct QuickFilterList: View {
    let filter: AppState.QuickFilter
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.quickFilteredSkills.isEmpty {
                ContentUnavailableView(
                    filter == .favorites ? "还没有收藏的 skills" : "还没有使用记录",
                    systemImage: filter == .favorites ? "star" : "clock",
                    description: Text(filter == .favorites ?
                        "点击 skill 旁的星标来添加收藏" : "使用过的 skills 会自动出现在这里")
                )
            } else {
                SkillListItems(skills: state.quickFilteredSkills)
            }
        }
        .navigationTitle(filter == .favorites ? "收藏夹" : "最近使用")
    }
}

// MARK: - Agent 过滤列表

struct AgentFilterList: View {
    let agentId: String
    @EnvironmentObject var state: AppState

    private var agentSkills: [Skill] {
        state.skills.filter { $0.presence[agentId] != nil }
    }

    var body: some View {
        Group {
            if agentSkills.isEmpty {
                ContentUnavailableView(
                    "该平台还没有 skills",
                    systemImage: "tray",
                    description: Text("尝试从其他平台同步 skills")
                )
            } else {
                SkillListItems(skills: agentSkills)
            }
        }
        .navigationTitle(state.targets.first(where: { $0.id == agentId })?.displayName ?? agentId)
    }
}

// MARK: - 场景列表

struct PresetList: View {
    let presetID: UUID
    @EnvironmentObject var state: AppState

    private var preset: SkillPreset? {
        state.presets.first { $0.id == presetID }
    }

    /// 组内仍存在的 skills（按场景内声明的顺序展示）
    private var presetSkills: [Skill] {
        guard let preset else { return [] }
        return preset.skillNames.compactMap { name in
            state.skills.first { $0.name == name }
        }
    }

    var body: some View {
        Group {
            if let preset {
                VStack(spacing: 0) {
                    presetHeader(preset)
                    Divider()
                    if preset.skillNames.isEmpty {
                        ContentUnavailableView(
                            "该场景还没有 skills",
                            systemImage: "rectangle.3.group",
                            description: Text("在 skill 详情页点击「加入场景」，把 skills 添加进来")
                        )
                    } else if presetSkills.isEmpty {
                        ContentUnavailableView(
                            "场景内的 skills 都已不存在",
                            systemImage: "questionmark.folder",
                            description: Text("这些 skills 可能已被删除，激活时会自动跳过并计入缺失")
                        )
                    } else {
                        SkillListItems(skills: presetSkills)
                    }
                }
            } else {
                ContentUnavailableView(
                    "场景不存在",
                    systemImage: "rectangle.3.group",
                    description: Text("该场景可能已被删除")
                )
            }
        }
        .navigationTitle(preset?.name ?? "场景")
    }

    private func presetHeader(_ preset: SkillPreset) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(preset.skillNames.count) 个 skill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // 目标平台编辑：点击 chip 切换生效平台；全部选中 = 不限制（targetIDs 为空）
                let editableTargets = state.targets.filter { $0.id != AgentTarget.canonicalID && $0.exists }
                let effectiveIDs = Set(PresetStore.effectiveTargets(for: preset, allTargets: state.targets).map(\.id))
                WrappingHStack(spacing: 4, lineSpacing: 4) {
                    Text("目标平台：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if editableTargets.isEmpty {
                        Text("没有可用的目标平台")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(editableTargets) { t in
                            let isOn = effectiveIDs.contains(t.id)
                            Button {
                                togglePresetTarget(preset, target: t, effectiveIDs: effectiveIDs)
                            } label: {
                                Text(t.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: Capsule())
                                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(isOn ? "点击从「\(preset.name)」的生效平台中移除" : "点击加入「\(preset.name)」的生效平台")
                        }
                        if preset.targetIDs.isEmpty {
                            Text("未限定 = 全部平台")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Spacer()
            Button {
                state.deactivatePreset(preset)
            } label: {
                Label("停用", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(preset.skillNames.isEmpty)

            Button {
                state.activatePreset(preset)
            } label: {
                Label("激活", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(preset.skillNames.isEmpty)
        }
        .padding(12)
    }

    /// 切换某个平台是否对场景生效：以当前生效集合为准做增删，
    /// 改回"全平台"时归一化为空数组（空 = 全部生效，兼容旧语义）
    private func togglePresetTarget(_ preset: SkillPreset, target: AgentTarget, effectiveIDs: Set<String>) {
        var next = effectiveIDs
        if next.contains(target.id) {
            next.remove(target.id)
        } else {
            next.insert(target.id)
        }
        let allIDs = Set(state.targets.filter { $0.id != AgentTarget.canonicalID }.map(\.id))
        let newTargetIDs = next == allIDs
            ? []
            : state.targets.filter { next.contains($0.id) }.map(\.id)
        state.setPresetTargets(preset, targetIDs: newTargetIDs)
    }
}

// MARK: - 作者过滤列表

struct AuthorFilterList: View {
    let author: String
    @EnvironmentObject var state: AppState

    private var authorSkills: [Skill] {
        // "其他"组包含多个不同作者，不能按 author 精确匹配，直接取归并组的 skills
        if author == SkillManager.miscAuthorGroupID {
            return state.authorGroups.first(where: \.isMisc)?.skills ?? []
        }
        return state.skills.filter { $0.author == author }
    }

    private var title: String {
        if author == SkillManager.miscAuthorGroupID { return "其他" }
        return author.isEmpty ? "未知作者" : author
    }

    var body: some View {
        Group {
            if authorSkills.isEmpty {
                ContentUnavailableView(
                    "该作者没有 skills",
                    systemImage: "person.circle",
                    description: Text("该作者名下的 skills 可能已被移除")
                )
            } else {
                SkillListItems(skills: authorSkills)
            }
        }
        .navigationTitle(title)
    }
}

// MARK: - 首页列表

struct HomeList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.isBusy && state.skills.isEmpty {
                // 首次扫描中
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在扫描 skills…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.skills.isEmpty {
                ContentUnavailableView(
                    "还没有发现任何 skills",
                    systemImage: "shippingbox",
                    description: Text("点击工具栏的「安装」从 GitHub 或本地目录添加，或在侧栏添加 Agent 平台")
                )
            } else {
                listContent
            }
        }
        .navigationTitle("SkillHub")
    }

    private var listContent: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    StatItem(title: "总数", value: "\(state.skills.count)", icon: "square.grid.2x2")
                    StatItem(title: "收藏", value: "\(state.favorites.count)", icon: "star.fill")
                    StatItem(title: "活跃", value: "\(state.usageInfo.filter { $0.category == .active }.count)", icon: "bolt.fill")
                    StatItem(title: "待同步", value: "\(state.platformCoverage.flatMap { $0.missing }.count)", icon: "arrow.triangle.2.circlepath")
                }
            }

            if !state.usageInfo.filter({ $0.category == .active }).isEmpty {
                Section("最近使用") {
                    ForEach(state.usageInfo.filter { $0.category == .active }.prefix(5), id: \.skill.id) { info in
                        SkillRow(skill: info.skill)
                            .tag(info.skill.id)
                            .onTapGesture {
                                state.selectedSkillForDetail = info.skill
                                state.selectedSkillID = info.skill.id
                            }
                    }
                }
            }

            let favSkills = state.skills.filter { state.favorites.contains($0.name) }
            if !favSkills.isEmpty {
                Section("收藏夹") {
                    ForEach(favSkills.prefix(5)) { skill in
                        SkillRow(skill: skill)
                            .tag(skill.id)
                            .onTapGesture {
                                state.selectedSkillForDetail = skill
                                state.selectedSkillID = skill.id
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 详情容器

struct DetailContainer: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            // 优先用 selectedSkillID 查到的最新数据，查不到时兜底用选中时缓存的对象
            if let skill = state.selectedSkill ?? state.selectedSkillForDetail {
                SkillDetailPanel(skill: skill)
            } else {
                // 未选中时展示总览仪表盘
                DashboardView()
            }
        }
    }
}

// MARK: - Skill 详情面板（三栏右栏）

struct SkillDetailPanel: View {
    let skill: Skill
    @EnvironmentObject var state: AppState
    @State private var markdown: String? = nil   // nil = 读取中；空串 = 读取失败或为空
    @State private var showNewPresetForSkill = false
    @State private var newPresetNameForSkill = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                agentMatrixSection
                if skill.hasAnalysis { aiAnalysisSection }
                if skill.gitRemote != nil { gitSection }
                actionsSection
                markdownSection
                directorySection
            }
            .padding(24)
        }
        .task(id: skill.id) {
            markdown = nil
            var text = (try? String(contentsOf: skill.skillMarkdownPath, encoding: .utf8)) ?? ""
            if text.count > 20_000 { text = String(text.prefix(20_000)) + "\n\n…" }
            markdown = text
        }
        .confirmationDialog("确定把 \(skill.name) 移入废纸篓？", isPresented: $confirmTrash) {
            Button("移入废纸篓", role: .destructive) { state.trash(skill: skill) }
            Button("取消", role: .cancel) {}
        }
        .alert("新建场景", isPresented: $showNewPresetForSkill) {
            TextField("场景名称，如：前端开发", text: $newPresetNameForSkill)
            Button("创建并加入") {
                let name = newPresetNameForSkill.trimmingCharacters(in: .whitespacesAndNewlines)
                state.createPreset(name: name)
                if let created = state.presets.first(where: { $0.name == name }) {
                    state.addSkillToPreset(created, skill: skill)
                }
                newPresetNameForSkill = ""
            }
            Button("取消", role: .cancel) { newPresetNameForSkill = "" }
        }
    }

    @State private var confirmTrash = false

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(skill.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if let v = skill.version {
                    Text("v\(v)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                }
                Spacer()
                HStack(spacing: 6) {
                    if skill.hasUpdate {
                        badge(icon: "arrow.triangle.down.circle.fill", text: "可更新", color: .green)
                    }
                    if skill.hasAnalysis {
                        badge(icon: "brain.fill", text: "已分析", color: .purple)
                    }
                    if !skill.hasFrontmatter {
                        badge(icon: "exclamationmark.triangle.fill", text: "缺 frontmatter", color: .orange)
                    }
                }
            }

            if !skill.descriptionText.isEmpty {
                Text(skill.descriptionText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                pill(icon: "doc", text: "\(skill.fileCount) 个文件")
                pill(icon: "internaldrive", text: skill.sizeDisplay)
                if !skill.author.isEmpty {
                    pill(icon: "person", text: skill.author)
                }
                if !skill.supportDirs.isEmpty {
                    pill(icon: "folder", text: skill.supportDirs.joined(separator: " · "))
                }
                if skill.gitRemote != nil {
                    pill(icon: "link", text: "Git")
                }
            }

            WrappingHStack(spacing: 4, lineSpacing: 4) {
                ForEach(skill.presence.keys.filter { $0 != AgentTarget.canonicalID }.sorted(), id: \.self) { agentID in
                    Label(agentID, systemImage: iconForAgent(agentID))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                        .fixedSize()
                }
            }

            Text(skill.canonicalPath.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }

    private func badge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private func pill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            .clipShape(Capsule())
    }

    // MARK: - Agent Matrix

    private var agentMatrixSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("平台状态", icon: "square.stack.3d.up")
            WrappingHStack(spacing: 6, lineSpacing: 6) {
                ForEach(state.targets.filter { $0.id != AgentTarget.canonicalID && $0.exists }) { t in
                    if skill.presence[t.id] != nil {
                        Label(t.displayName, systemImage: iconForAgent(t.id))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }
                if state.targets.filter({ $0.id != AgentTarget.canonicalID && $0.exists }).allSatisfy({ skill.presence[$0.id] == nil }) {
                    Text("未启用在任何平台")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // 以副本方式启用：复制本体到平台目录（而非软链），适合需要离线/独立分发的平台
            let copyCandidates = state.targets.filter {
                $0.id != AgentTarget.canonicalID && $0.exists && skill.presence[$0.id] == nil
            }
            if !copyCandidates.isEmpty {
                Menu {
                    ForEach(copyCandidates) { t in
                        Button {
                            state.copyEnable(skill: skill, to: t)
                        } label: {
                            Label(t.displayName, systemImage: iconForAgent(t.id))
                        }
                    }
                } label: {
                    Label("以副本方式启用到…", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("复制本体到平台目录（副本带标记，禁用/删除时会一并清理）")
            }
        }
    }

    private func iconForAgent(_ id: String) -> String {
        switch id {
        case "agents": return "shippingbox"
        case "claude": return "brain"
        case "cursor": return "cursorarrow"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "gearshape"
        }
    }

    // MARK: - AI Analysis

    private var aiAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("AI 分析", icon: "brain")
            VStack(alignment: .leading, spacing: 8) {
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !skill.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(skill.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.purple.opacity(0.1))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Git

    private var gitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Git 来源", icon: "link")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let remote = skill.gitRemote {
                        Image(systemName: "globe")
                            .foregroundStyle(.blue)
                        Text(remote)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                    Spacer()
                    if let branch = skill.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    if let commit = skill.gitLastCommit {
                        Text(commit)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                if skill.hasUpdate {
                    HStack {
                        Image(systemName: "arrow.triangle.down.circle.fill")
                            .foregroundStyle(.green)
                        Text("有新版本可用")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Button {
                            state.pullUpdate(for: skill)
                        } label: {
                            Label("更新", systemImage: "arrow.triangle.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("操作", icon: "wrench.and.screwdriver")
            HStack(spacing: 8) {
                Button {
                    SkillOps.copyInvokePrompt(skill: skill)
                    state.postNotice("触发词已复制")
                } label: {
                    Label("复制触发词", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    SkillOps.copySkillMarkdown(skill: skill)
                    state.postNotice("SKILL.md 已复制")
                } label: {
                    Label("复制 SKILL.md", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    SkillOps.openInEditor(skill.skillMarkdownPath)
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    SkillOps.revealInFinder(skill.canonicalPath)
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // 加入场景：列出所有场景（已加入的可点击移出），或新建场景并加入
                Menu {
                    if state.presets.isEmpty {
                        Text("还没有场景")
                    } else {
                        ForEach(state.presets) { preset in
                            Button {
                                if preset.skillNames.contains(skill.name) {
                                    state.removeSkillFromPreset(preset, skill: skill)
                                } else {
                                    state.addSkillToPreset(preset, skill: skill)
                                }
                            } label: {
                                Label(preset.name,
                                      systemImage: preset.skillNames.contains(skill.name) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    Divider()
                    Button("新建场景并加入…") {
                        newPresetNameForSkill = ""
                        showNewPresetForSkill = true
                    }
                } label: {
                    Label("加入场景", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if state.isFavorite(skill) {
                    Button {
                        state.toggleFavorite(skill)
                    } label: {
                        Label("取消收藏", systemImage: "star.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        state.toggleFavorite(skill)
                    } label: {
                        Label("收藏", systemImage: "star.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    confirmTrash = true
                } label: {
                    Label("废纸篓", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.8))
                .controlSize(.small)
            }
        }
    }

    // MARK: - Markdown

    private var markdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("SKILL.md", icon: "doc.text")
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let markdown {
                        Text(markdown.isEmpty ? "（无法读取 SKILL.md 或文件为空）" : markdown)
                    } else {
                        Text("（读取中…）")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
        }
    }

    // MARK: - Directory

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("目录结构", icon: "folder")
            DirectoryTreeView(path: skill.canonicalPath)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Color.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX)
        }

        return (CGSize(width: totalWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - 目录结构树视图

struct DirectoryTreeView: View {
    let path: URL
    @State private var children: [FileNode] = []
    @State private var isExpanded = true

    struct FileNode: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
        let isDirectory: Bool
        var children: [FileNode]?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { node in
                    FileNodeRow(node: node, depth: 1)
                }
            } label: {
                Label(path.lastPathComponent, systemImage: "folder.fill")
                    .font(.subheadline.monospaced())
            }
        }
        .task(id: path) {
            children = buildTree(at: path, maxDepth: 3)
        }
    }

    private func buildTree(at url: URL, maxDepth: Int) -> [FileNode] {
        guard maxDepth > 0 else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { item in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(
                name: item.lastPathComponent,
                url: item,
                isDirectory: isDir,
                children: isDir ? buildTree(at: item, maxDepth: maxDepth - 1) : nil
            )
        }
    }
}

struct FileNodeRow: View {
    let node: DirectoryTreeView.FileNode
    let depth: Int
    @State private var isExpanded = false
    @State private var showFileContent = false
    @State private var fileContent: String = ""

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let children = node.children {
                    ForEach(children) { child in
                        FileNodeRow(node: child, depth: depth + 1)
                    }
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .font(.caption.monospaced())
            }
        } else {
            Button {
                loadFileContent()
                showFileContent = true
            } label: {
                Label(node.name, systemImage: fileIcon(for: node.name))
                    .font(.caption.monospaced())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFileContent) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(node.name)
                            .font(.headline)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fileContent, forType: .string)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        Text(fileContent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: 500, height: 400)
                .padding()
            }
        }
    }

    private func loadFileContent() {
        guard let data = try? Data(contentsOf: node.url),
              let content = String(data: data, encoding: .utf8) else {
            fileContent = "(无法读取)"
            return
        }
        let lines = content.components(separatedBy: .newlines)
        if lines.count > 200 {
            fileContent = lines.prefix(200).joined(separator: "\n") + "\n\n... (共 \(lines.count) 行)"
        } else {
            fileContent = content
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md": return "doc.text"
        case "swift": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "yaml", "yml": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "sh", "bash": return "terminal"
        default: return "doc"
        }
    }
}

// MARK: - Command Palette

struct CommandPaletteSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var results: [SkillManager.SearchResult] {
        SkillManager.search(skills: state.skills, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索 skills...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            if results.isEmpty && !searchText.isEmpty {
                ContentUnavailableView("没有找到匹配的 skills", systemImage: "magnifyingglass")
            } else {
                List(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.skill.name)
                                .font(.headline)
                            Spacer()
                            Text(result.matchReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !result.skill.descriptionText.isEmpty {
                            Text(result.skill.descriptionText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .onTapGesture {
                        state.selectedSkillForDetail = result.skill
                        state.selectedSkillID = result.skill.id
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .onAppear { isSearchFocused = true }
    }
}

// MARK: - 添加自定义 Agent 平台

struct AddAgentSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var agentName = ""
    @State private var agentPath = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var detectedPlatforms: [DetectedPlatform] = []
    @State private var isScanning = false

    struct DetectedPlatform: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let skillsPath: String
        let isAlreadyAdded: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("添加自定义平台")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            TabView {
                // Tab 1: 自动检测
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text("自动检测到的平台")
                                .font(.subheadline.bold())
                            Spacer()
                            if isScanning {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Text("系统检测到以下可能的 Agent 平台目录：")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if detectedPlatforms.isEmpty && !isScanning {
                            ContentUnavailableView(
                                "未检测到其他平台",
                                systemImage: "folder.badge.questionmark",
                                description: Text("你可以手动添加平台目录")
                            )
                        } else {
                            ForEach(detectedPlatforms) { platform in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(platform.name)
                                            .font(.subheadline.bold())
                                        Text(platform.skillsPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if platform.isAlreadyAdded {
                                        Text("已添加")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else {
                                        Button("添加") {
                                            addDetectedPlatform(platform)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding()
                }
                .tabItem {
                    Label("自动检测", systemImage: "wand.and.stars")
                }

                // Tab 2: 手动添加
                Form {
                    LabeledContent("平台名称") {
                        TextField("例如：My Agent", text: $agentName)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Skills 目录") {
                        TextField("例如：~/.myagent/skills", text: $agentPath)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("输入包含 skills 的目录路径。系统将扫描该目录中的所有 skill。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("手动添加", systemImage: "plus.circle")
                }
            }
            .frame(height: 300)

            Divider()

            // 按钮
            HStack {
                Spacer()
                Button("添加") {
                    addManualAgent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(agentName.isEmpty || agentPath.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 420)
        .alert("无法添加平台", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            scanForPlatforms()
        }
    }

    private func scanForPlatforms() {
        isScanning = true
        detectedPlatforms = []

        let home = FileManager.default.homeDirectoryForCurrentUser
        let knownPlatforms: [(name: String, path: String)] = [
            ("Claude Code", ".claude"),
            ("Cursor", ".cursor"),
            ("Codex", ".codex"),
            ("Qoder", ".qoder"),
            ("iFlow", ".iflow"),
            ("Aider", ".aider"),
            ("Continue", ".continue"),
            ("Cline", ".cline"),
            ("Roo Code", ".roo"),
            ("Windsurf", ".codeium"),
            ("Supermaven", ".supermaven"),
            ("Tabnine", ".tabnine"),
            ("CodeGeeX", ".codegeex"),
            ("Amazon Q", ".amazonq"),
            ("GitHub Copilot", ".copilot"),
            ("Sourcegraph Cody", ".cody"),
            ("Zed", ".zed"),
            ("Nova", ".nova"),
            ("PyCharm", ".pycharm"),
            ("IntelliJ", ".intellij"),
            ("VS Code", ".vscode"),
            ("Neovim", ".config/nvim"),
        ]

        for platform in knownPlatforms {
            let skillsPath = home.appendingPathComponent("\(platform.path)/skills")
            let altSkillsPath = home.appendingPathComponent("\(platform.path)/commands")
            let altSkillsPath2 = home.appendingPathComponent("\(platform.path)/prompts")

            let actualPath: String?
            if FileManager.default.fileExists(atPath: skillsPath.path) {
                actualPath = skillsPath.path
            } else if FileManager.default.fileExists(atPath: altSkillsPath.path) {
                actualPath = altSkillsPath.path
            } else if FileManager.default.fileExists(atPath: altSkillsPath2.path) {
                actualPath = altSkillsPath2.path
            } else {
                actualPath = nil
            }

            if let path = actualPath {
                let isAdded = state.customAgentTargets.contains { $0.displayName == platform.name }
                detectedPlatforms.append(DetectedPlatform(
                    name: platform.name,
                    path: path,
                    skillsPath: path,
                    isAlreadyAdded: isAdded
                ))
            }
        }

        isScanning = false
    }

    private func addDetectedPlatform(_ platform: DetectedPlatform) {
        state.addCustomAgent(name: platform.name, path: platform.skillsPath)
        detectedPlatforms = detectedPlatforms.map { p in
            if p.id == platform.id {
                return DetectedPlatform(name: p.name, path: p.path, skillsPath: p.skillsPath, isAlreadyAdded: true)
            }
            return p
        }
    }

    private func addManualAgent() {
        let path = (agentPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false

        guard !agentName.trimmingCharacters(in: .whitespaces).isEmpty else {
            showError = true
            errorMessage = "请输入平台名称"
            return
        }

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue else {
            showError = true
            errorMessage = "目录不存在或不是一个文件夹"
            return
        }

        state.addCustomAgent(name: agentName, path: path)
        dismiss()
    }
}
