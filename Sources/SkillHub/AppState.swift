import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var targets: [AgentTarget] = AgentTarget.builtin()
    @Published var skills: [Skill] = []
    @Published var brokenLinks: [(agentID: String, url: URL, destination: String)] = []
    @Published var issues: [DoctorIssue] = []
    @Published var searchText: String = ""
    @Published var selectedAgentFilter: String? = nil   // nil = 全部
    @Published var selectedSkillID: String? = nil
    @Published var lastError: String? = nil
    @Published var lastNotice: String? = nil
    @Published var isBusy = false

    // MARK: - 搜索增强
    @Published var selectedTagFilter: String? = nil      // nil = 全部标签
    @Published var sortBy: SortOption = .name

    enum SortOption: String, CaseIterable {
        case name = "名称"
        case size = "体积"
        case files = "文件数"
        case tagCount = "标签数"
    }

    // MARK: - 标签聚合
    // 说明：原先这里有 _allTags / _filteredSkills / _quickFilteredSkills 三个缓存，
    // 但 skills 更新后缓存不会失效（会返回陈旧数据），且后两个从未被使用，
    // 因此移除缓存，直接实时计算（数据量小，开销可忽略）。
    var allTags: [String] {
        Array(Set(skills.flatMap(\.tags))).sorted()
    }

    // MARK: - 更新检测状态
    @Published var updateChecking = false
    @Published var updateProgressDone = 0
    @Published var updateProgressTotal = 0
    @Published var updateResults: [String: UpdateChecker.UpdateInfo] = [: ]

    // MARK: - 智能管家状态
    @Published var showManager = false
    @Published var showDoctor = false
    @Published var showInstall = false
    @Published var sourceGroups: [SkillManager.SourceGroup] = []
    @Published var platformCoverage: [SkillManager.PlatformCoverage] = []
    @Published var usageInfo: [SkillManager.UsageInfo] = []
    @Published var redundancyGroups: [SkillManager.RedundancyGroup] = []
    @Published var cleanupSuggestions: [SkillManager.CleanupSuggestion] = []
    @Published var lockFile: SkillLockFile?

    // MARK: - 新 UX 状态
    @Published var smartSearchQuery: String = ""
    @Published var searchResults: [SkillManager.SearchResult] = []
    @Published var categorizedSkills: [SkillManager.CategorizedSkills] = []
    @Published var selectedCategory: SkillManager.SkillCategory? = nil
    @Published var authorGroups: [SkillManager.AuthorGroup] = []
    @Published var selectedAuthor: String? = nil   // nil = 全部; "" = 未知作者; SkillManager.miscAuthorGroupID = "其他"组
    @Published var selectedSkillForDetail: Skill? = nil
    @Published var showCommandPalette = false
    @Published var favorites: [String] = SkillManager.favorites
    @Published var isSidebarCollapsed = false

    // MARK: - 场景（Preset）
    @Published var presets: [SkillPreset] = PresetStore().load()
    @Published var selectedPresetID: UUID? = nil
    private let presetStore = PresetStore()

    // MARK: - 项目工作区
    @Published var projectWorkspaces: [ProjectWorkspace] = []
    /// 扫描结果按需加载：选中项目时扫描并缓存，项目 id → skills 条目
    @Published var projectScanResults: [UUID: [ProjectSkillEntry]] = [:]
    /// 正在扫描的项目 id（用于行内进度指示；nil = 空闲）
    @Published var scanningProjectID: UUID? = nil
    private let projectStore = ProjectWorkspaceStore()

    init() {
        projectWorkspaces = projectStore.workspaces
    }

    // MARK: - 自定义 Agent 平台
    @AppStorage("customAgentTargets") private var customAgentTargetsRaw: String = ""

    var customAgentTargets: [AgentTarget] {
        get {
            guard let data = customAgentTargetsRaw.data(using: .utf8),
                  let items = try? JSONDecoder().decode([AgentTarget].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                customAgentTargetsRaw = json
            }
        }
    }

    enum QuickFilter: Equatable {
        case favorites
        case recent
    }
    @Published var selectedQuickFilter: QuickFilter? = nil

    var lockFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/.skill-lock.json")
    }

    /// 用户自定义扫描目录（持久化）
    @AppStorage("customDirs") private var customDirsRaw: String = ""

    var customDirs: [String] {
        get { customDirsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set { customDirsRaw = newValue.joined(separator: "\n") }
    }

    var storeDir: URL {
        targets.first(where: { $0.id == AgentTarget.canonicalID })?.dir
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills")
    }

    var allTargets: [AgentTarget] {
        var list = AgentTarget.builtin()
        // 添加自定义目录
        for (i, dir) in customDirs.enumerated() {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            list.append(AgentTarget(id: "custom\(i)", displayName: url.lastPathComponent, dir: url))
        }
        // 添加自定义 Agent 平台
        list.append(contentsOf: customAgentTargets)
        // 按实际目录去重：内置平台优先，剔除指向同一目录的重复项
        return AgentTarget.deduplicatedByDirectory(list)
    }

    var filteredSkills: [Skill] {
        var list = skills
        if let agent = selectedAgentFilter {
            list = list.filter { $0.presence[agent] != nil }
        }
        if let tag = selectedTagFilter {
            list = list.filter { $0.tags.contains(tag) }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q) ||
                $0.descriptionText.localizedCaseInsensitiveContains(q) ||
                $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            }
        }
        switch sortBy {
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            list.sort { $0.sizeBytes > $1.sizeBytes }
        case .files:
            list.sort { $0.fileCount > $1.fileCount }
        case .tagCount:
            list.sort { $0.tags.count > $1.tags.count }
        }
        return list
    }

    var quickFilteredSkills: [Skill] {
        switch selectedQuickFilter {
        case .favorites:
            return skills.filter { favorites.contains($0.name) }
        case .recent:
            return usageInfo.filter { $0.category == .active }.map(\.skill)
        case nil:
            return filteredSkills
        }
    }

    var selectedSkill: Skill? {
        skills.first { $0.id == selectedSkillID }
    }

    var stats: (total: Int, orphan: Int, errors: Int, warnings: Int, totalSize: Int64, updatable: Int) {
        let orphan = skills.filter { s in
            s.presence.keys.filter { $0 != AgentTarget.canonicalID }.isEmpty
        }.count
        return (
            skills.count,
            orphan,
            issues.filter { $0.severity == .error }.count,
            issues.filter { $0.severity == .warning }.count,
            skills.reduce(0) { $0 + $1.sizeBytes },
            skills.filter(\.hasUpdate).count
        )
    }

    /// 自动检测已知平台并添加
    func autoDetectPlatforms() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        let knownPlatforms: [(name: String, folder: String)] = [
            ("Claude Code", ".claude"),
            ("Codex", ".codex"),
            ("Cline", ".cline"),
            ("Windsurf", ".windsurf"),
        ]

        var added = 0
        var existing = customAgentTargets

        for (name, folder) in knownPlatforms {
            let platformDir = home.appendingPathComponent(folder)
            let skillsDir = platformDir.appendingPathComponent("skills")

            guard fm.fileExists(atPath: skillsDir.path) else { continue }

            let id = "auto_\(folder.replacingOccurrences(of: ".", with: ""))"
            let candidate = AgentTarget(id: id, displayName: name, dir: skillsDir)

            // 已存在（内置或自定义）则跳过——按实际目录判重，而非仅比对 id，
            // 否则内置的 "claude" 与自动检测的 "auto_claude" 会指向同一目录造成重复
            let existingDirs = Set(AgentTarget.builtin().map(\.directoryKey) + existing.map(\.directoryKey))
            guard !existingDirs.contains(candidate.directoryKey) else { continue }

            existing.append(candidate)
            added += 1
        }

        if added > 0 {
            customAgentTargets = existing
        }
    }

    /// 迁移清理：剔除与内置平台指向同一目录、或彼此目录重复的持久化自定义平台
    ///（早期版本按 id 判重，会把同一目录以 "auto_xxx" 重复保存）
    private func sanitizeCustomAgentTargets() {
        let custom = customAgentTargets
        guard !custom.isEmpty else { return }
        var seen = Set(AgentTarget.builtin().map(\.directoryKey))
        let cleaned = custom.filter { seen.insert($0.directoryKey).inserted }
        if cleaned.count != custom.count {
            customAgentTargets = cleaned
        }
    }

    /// 刷新 skills 列表。
    /// - force: false 时走逐 skill 指纹缓存（启动秒开，只有变化的 skill 才重扫）；
    ///   true 时绕过缓存全量重扫（手动「刷新 / 重新体检」按钮）。
    ///
    /// 两阶段设计：
    /// 1. plan + execute（缓存命中时毫秒级）后**立刻**把 skills 应用到界面；
    /// 2. 安全扫描报告很贵（遍历每个 skill 的全部文本文件），只补扫没有缓存报告的 skill，
    ///    扫完再跑体检并应用 issues。界面不会被体检阻塞。
    func refresh(force: Bool = false) {
        sanitizeCustomAgentTargets()
        autoDetectPlatforms()
        let targets = allTargets
        self.targets = targets
        Task.detached { [weak self] in
            let cached = force ? nil : ScanCache.load()
            let plan = SkillScanner.plan(targets: targets)
            // 只有真的需要重扫时才显示「扫描中」，缓存全命中则静默完成
            if force || !plan.fullyCovered(by: cached) {
                Task { @MainActor [weak self] in
                    self?.isBusy = true
                }
            }
            var result = SkillScanner.execute(plan: plan, cache: cached)
            result.cache.save()
            let lockFile = SkillLockFile.load(from: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/.skill-lock.json"))

            // 第一阶段：立刻应用 skills，界面秒出数据
            let outcomeForUI = result.outcome
            Task { @MainActor [weak self] in
                self?.skills = outcomeForUI.skills
                self?.brokenLinks = outcomeForUI.brokenLinks
                self?.lockFile = lockFile
                self?.refreshManager()
                self?.isBusy = false
            }

            // 第二阶段：补扫缺失的安全报告（结果回写缓存），然后跑体检
            var entries = result.cache.entries
            var scannedAny = false
            for i in result.outcome.skills.indices where result.outcome.skills[i].securityReport == nil {
                let report = SecurityScanner.scan(skill: result.outcome.skills[i])
                result.outcome.skills[i].securityReport = report
                let path = result.outcome.skills[i].canonicalPath.path
                entries[path]?.securityFindings = report.findings
                entries[path]?.securityScore = report.score
                scannedAny = true
            }
            if scannedAny {
                ScanCache(version: ScanCache.formatVersion, entries: entries).save()
            }
            let issues = Doctor.run(outcome: result.outcome, targets: targets)
            Task { @MainActor [weak self] in
                self?.issues = issues
                self?.refreshManager()
            }
        }
    }

    func refreshManager() {
        sourceGroups = SkillManager.groupBySource(skills: skills, lockFile: lockFile)
        platformCoverage = SkillManager.analyzeCoverage(skills: skills, targets: targets)
        usageInfo = SkillManager.analyzeUsage(skills: skills)
        redundancyGroups = SkillManager.detectRedundancy(skills: skills)
        cleanupSuggestions = SkillManager.suggestCleanup(skills: skills, targets: targets, issues: issues)
        categorizedSkills = SkillManager.categorize(skills: skills)
        authorGroups = SkillManager.groupByAuthor(skills: skills)
        favorites = SkillManager.favorites
    }

    func performSmartSearch() {
        searchResults = SkillManager.search(skills: skills, query: smartSearchQuery)
    }

    func toggleFavorite(_ skill: Skill) {
        SkillManager.toggleFavorite(skill)
        favorites = SkillManager.favorites
    }

    func isFavorite(_ skill: Skill) -> Bool {
        favorites.contains(skill.name)
    }

    // MARK: - 场景（Preset）管理

    func createPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !presets.contains(where: { $0.name == trimmed }) else {
            notice("已存在同名场景：\(trimmed)")
            return
        }
        var list = presets
        let preset = PresetStore.add(&list, name: trimmed)
        presets = list
        presetStore.save(list)
        selectedPresetID = preset.id
        notice("已创建场景：\(trimmed)")
    }

    func deletePreset(_ preset: SkillPreset) {
        var list = presets
        PresetStore.remove(&list, id: preset.id)
        presets = list
        presetStore.save(list)
        if selectedPresetID == preset.id { selectedPresetID = nil }
        notice("已删除场景：\(preset.name)")
    }

    func renamePreset(_ preset: SkillPreset, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = presets
        PresetStore.rename(&list, id: preset.id, name: trimmed)
        presets = list
        presetStore.save(list)
        notice("已重命名为：\(trimmed)")
    }

    func addSkillToPreset(_ preset: SkillPreset, skill: Skill) {
        guard !preset.skillNames.contains(skill.name) else {
            notice("\(skill.name) 已在「\(preset.name)」中")
            return
        }
        var list = presets
        PresetStore.addSkill(&list, id: preset.id, skillName: skill.name)
        presets = list
        presetStore.save(list)
        notice("已把 \(skill.name) 加入「\(preset.name)」")
    }

    func removeSkillFromPreset(_ preset: SkillPreset, skill: Skill) {
        var list = presets
        PresetStore.removeSkill(&list, id: preset.id, skillName: skill.name)
        presets = list
        presetStore.save(list)
        notice("已把 \(skill.name) 移出「\(preset.name)」")
    }

    /// 激活场景：对组内每个 skill 在每个生效平台执行 enable，最后统一刷新一次
    func activatePreset(_ preset: SkillPreset) {
        let effective = PresetStore.effectiveTargets(for: preset, allTargets: targets)
        guard !effective.isEmpty else {
            lastError = "没有可用的目标平台"
            return
        }
        let result = PresetOps.activate(preset: preset, skills: skills, targets: effective)
        notice(PresetOps.summary(action: "激活", preset: preset, result: result))
        if !result.failed.isEmpty {
            lastError = result.failed.joined(separator: "\n")
        }
        refresh()
    }

    /// 停用场景：同理执行 disable（本体目录绝不删除），最后统一刷新一次
    func deactivatePreset(_ preset: SkillPreset) {
        let effective = PresetStore.effectiveTargets(for: preset, allTargets: targets)
        guard !effective.isEmpty else {
            lastError = "没有可用的目标平台"
            return
        }
        let result = PresetOps.deactivate(preset: preset, skills: skills, targets: effective)
        notice(PresetOps.summary(action: "停用", preset: preset, result: result))
        if !result.failed.isEmpty {
            lastError = result.failed.joined(separator: "\n")
        }
        refresh()
    }

    /// 改写场景的目标平台集合并持久化（空数组 = 全部平台生效）
    func setPresetTargets(_ preset: SkillPreset, targetIDs: [String]) {
        var list = presets
        PresetStore.setTargets(&list, id: preset.id, targetIDs: targetIDs)
        presets = list
        presetStore.save(list)
    }

    // MARK: - 项目工作区

    /// 注册项目目录（名称默认取目录名），重复注册时给出错误反馈
    func addProject(path: URL) {
        do {
            let ws = try projectStore.add(path: path)
            projectWorkspaces = projectStore.workspaces
            notice("已添加项目：\(ws.name)")
            scanProject(ws)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeProject(id: UUID) {
        let name = projectWorkspaces.first(where: { $0.id == id })?.name
        projectStore.remove(id: id)
        projectWorkspaces = projectStore.workspaces
        projectScanResults[id] = nil
        notice("已移除项目\(name.map { "：\($0)" } ?? "")")
    }

    /// 按需扫描项目里的 skills（重复调用直接重扫刷新缓存）
    func scanProject(_ workspace: ProjectWorkspace) {
        guard scanningProjectID == nil else { return }
        scanningProjectID = workspace.id
        Task.detached { [weak self] in
            do {
                let entries = try ProjectScanner.scan(workspace: workspace)
                Task { @MainActor [weak self] in
                    self?.projectScanResults[workspace.id] = entries
                    self?.scanningProjectID = nil
                }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.projectScanResults[workspace.id] = []
                    self?.scanningProjectID = nil
                    self?.lastError = msg
                }
            }
        }
    }

    /// 把项目里的 skill 复制进本体库（同名冲突报错不覆盖）
    func importProjectSkill(_ entry: ProjectSkillEntry, from workspace: ProjectWorkspace) {
        do {
            try ProjectSync.importToStore(entry: entry, workspace: workspace, storeDir: storeDir)
            notice("已把 \(entry.skillName) 收进本体库")
            refresh()
            scanProject(workspace)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 把本体库 skill 复制到项目的约定子目录（默认 .claude/skills）
    func exportSkillToProject(_ skill: Skill, to workspace: ProjectWorkspace, subdir: String = ".claude/skills") {
        do {
            try ProjectSync.exportToProject(skillCanonicalPath: skill.canonicalPath, workspace: workspace, subdir: subdir)
            notice("已把 \(skill.name) 导入项目「\(workspace.name)」")
            scanProject(workspace)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 自定义 Agent 平台管理

    func addCustomAgent(name: String, path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let id = "custom_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"
        let newTarget = AgentTarget(id: id, displayName: name, dir: url)

        var targets = customAgentTargets
        // 检查是否已存在
        if !targets.contains(where: { $0.id == id }) {
            targets.append(newTarget)
            customAgentTargets = targets
            refresh()
            notice("已添加自定义平台: \(name)")
        }
    }

    func removeCustomAgent(id: String) {
        var targets = customAgentTargets
        targets.removeAll { $0.id == id }
        customAgentTargets = targets
        refresh()
        notice("已移除自定义平台")
    }

    // MARK: - 操作封装（统一错误提示 + 刷新）

    func toggle(skill: Skill, target: AgentTarget) {
        do {
            if skill.presence[target.id] != nil {
                try SkillOps.disable(skill: skill, in: target)
                notice("已从 \(target.displayName) 移除 \(skill.name)")
            } else {
                try SkillOps.enable(skill: skill, in: target)
                notice("已在 \(target.displayName) 启用 \(skill.name)")
            }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 以副本方式启用：把本体完整复制到平台目录（副本带 .skillhub-copy 标记，
    /// disable/trash 会识别并允许删除）。错误处理与 refresh 复用 toggle 的模式。
    func copyEnable(skill: Skill, to target: AgentTarget) {
        do {
            try SkillOps.enable(skill: skill, in: target, mode: .copy)
            notice("已把 \(skill.name) 复制到 \(target.displayName)")
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func trash(skill: Skill) {
        do {
            try SkillOps.trash(skill: skill, targets: targets)
            notice("已把 \(skill.name) 移入废纸篓")
            selectedSkillID = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 批量操作

    func syncToAll(skill: Skill) {
        let result = SkillManager.syncToAll(skill: skill, targets: targets)
        if result.failed.isEmpty {
            notice("已同步 \(skill.name) 到所有平台（\(result.success) 个）")
        } else {
            notice("同步了 \(result.success) 个，\(result.failed.count) 个失败")
        }
        refresh()
    }

    func batchEnable(skills: [Skill], to target: AgentTarget) {
        var success = 0
        for skill in skills {
            do {
                if skill.presence[target.id] == nil {
                    try SkillOps.enable(skill: skill, in: target)
                    success += 1
                }
            } catch {}
        }
        notice("已批量启用 \(success) 个 skills 到 \(target.displayName)")
        refresh()
    }

    func batchDisable(skills: [Skill], from target: AgentTarget) {
        var success = 0
        for skill in skills {
            do {
                if skill.presence[target.id] != nil {
                    try SkillOps.disable(skill: skill, in: target)
                    success += 1
                }
            } catch {}
        }
        notice("已从 \(target.displayName) 批量禁用 \(success) 个 skills")
        refresh()
    }

    // MARK: - 一键收编到本体库

    /// 本体不在本体库的 skills（散落在各平台目录里的真实目录；
    /// 本体库已有软链指向同一本体的不算散落）
    var straySkills: [Skill] {
        skills.filter { !SkillManager.isRepresentedInStore(skill: $0, storeDir: storeDir) }
    }

    /// 一键收编：把所有散落的本体迁移进本体库，并在原平台目录留下软链
    func migrateAllToStore() {
        let strays = straySkills
        guard !strays.isEmpty else {
            notice("所有 skills 都已在本体库中")
            return
        }
        isBusy = true
        let store = storeDir
        let currentTargets = targets
        Task.detached { [weak self] in
            var migrated = 0
            var relinked = 0
            var failed: [(String, String)] = []
            for skill in strays {
                // 找到本体当前所在的平台目录（含自定义平台），迁移后在那里补软链
                let owner = currentTargets.first { SkillManager.isPath(skill.canonicalPath, inside: $0.dir) }
                do {
                    // 本体库的同名入口若是指向别处的软链：软链只是指针，删掉再迁移，不伤真实数据
                    let storeEntry = store.appendingPathComponent(skill.canonicalPath.lastPathComponent)
                    if (try? FileManager.default.destinationOfSymbolicLink(atPath: storeEntry.path)) != nil {
                        try FileManager.default.removeItem(at: storeEntry)
                    }
                    try SkillOps.migrateToStore(skillPath: skill.canonicalPath, target: owner, storeDir: store)
                    migrated += 1
                } catch {
                    // 同名冲突：本体库已有同名 skill。若散落的版本不比本体库新，
                    // 直接"链接化"——散落目录进废纸篓（可恢复），原地改建指向本体库的软链
                    let storeVersion = store.appendingPathComponent(skill.canonicalPath.lastPathComponent)
                    let strayDate = SkillManager.modificationDate(of: skill.canonicalPath)
                    let storeDate = SkillManager.modificationDate(of: storeVersion)
                    let strayIsNewer = strayDate != nil && storeDate != nil && strayDate! > storeDate!
                    let storeHasSameName = FileManager.default.fileExists(atPath: storeVersion.path)

                    if storeHasSameName && !strayIsNewer && owner != nil {
                        do {
                            try SkillOps.relinkToStore(skillPath: skill.canonicalPath, target: owner, storeDir: store)
                            relinked += 1
                        } catch {
                            failed.append((skill.name, error.localizedDescription))
                        }
                    } else if storeHasSameName && strayIsNewer {
                        failed.append((skill.name, "本体库已有同名，但散落的版本更新，已跳过，请手动合并"))
                    } else {
                        failed.append((skill.name, error.localizedDescription))
                    }
                }
            }
            // 在后台算好文案，跳回 MainActor 时只携带不可变值（避免并发捕获警告）
            var parts: [String] = []
            if migrated > 0 { parts.append("收编 \(migrated) 个") }
            if relinked > 0 { parts.append("链接 \(relinked) 个到已有版本") }
            if !failed.isEmpty { parts.append("\(failed.count) 个失败") }
            let message = parts.isEmpty ? "没有需要处理的 skills" : (failed.isEmpty ? "已\(parts.joined(separator: "，"))" : parts.joined(separator: "，"))
            let detail = failed.isEmpty ? nil : failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            Task { @MainActor [weak self] in
                self?.finishBusyOperation(message: message, error: detail)
            }
        }
    }

    func fixIssue(_ issue: DoctorIssue) {
        guard issue.fixAction != .none else { return }
        do {
            switch issue.fixAction {
            case .deleteBrokenLink(let url):
                try SkillOps.removeBrokenLink(at: url)
                notice("已删除断链 \(url.lastPathComponent)")
            case .addFrontmatter(let url):
                try SkillOps.addFrontmatter(to: url)
                notice("已补 frontmatter")
            case .addDescription(let url, let desc):
                try SkillOps.addDescription(to: url, description: desc)
                notice("已补 description")
            case .renameDirectory(let url, let name):
                try SkillOps.renameDirectory(from: url, to: name)
                notice("已重命名为 \(name)")
            case .removeReference(let url, let ref):
                try SkillOps.removeReference(from: url, reference: ref)
                notice("已移除引用 \(ref)")
            case .enableInAgent(let path, let agentID):
                try SkillOps.enableInAgent(skillPath: path, agentID: agentID)
                notice("已启用到 \(agentID)")
            case .migrateToStore(let path, let agentID):
                try SkillOps.migrateToStore(skillPath: path, agentID: agentID, storeDir: storeDir)
                notice("已迁移到本体库")
            case .none:
                return
            }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fixAllIssues() {
        let fixable = issues.filter { $0.fixAction != .none }
        let currentTargets = targets
        guard !fixable.isEmpty else { return }
        isBusy = true
        Task.detached { [weak self] in
            let result = SkillOps.fixAll(fixable, targets: currentTargets)
            let message = result.failed.isEmpty
                ? "已修复 \(result.fixed) 个问题"
                : "修复了 \(result.fixed) 个，\(result.failed.count) 个失败"
            Task { @MainActor [weak self] in
                self?.finishBusyOperation(message: message, error: nil)
            }
        }
    }

    func install(source: String, enableIn: [AgentTarget], completion: @escaping (Bool) -> Void) {
        isBusy = true
        let store = storeDir
        let lockURL = lockFileURL
        Task.detached { [weak self] in
            do {
                let result = try SkillOps.installWithRef(
                    source: source,
                    storeDir: store,
                    enableTargets: enableIn,
                    lockFileURL: lockURL
                )
                let names = result.installed.joined(separator: ", ")
                // @tag 安装时把实际 checkout 的版本号带进通知
                let versionNote = result.resolvedRef.map { "（版本 \($0)）" } ?? ""
                Task { @MainActor [weak self] in
                    self?.notice("安装成功：\(names)\(versionNote)")
                    self?.isBusy = false
                    self?.refresh()
                    completion(true)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = error.localizedDescription
                    self?.isBusy = false
                    completion(false)
                }
            }
        }
    }

    // MARK: - 技能市场

    @Published var showMarketplace = false

    /// 冻结并检查任意安装来源，不修改本体库。
    func prepareInstall(source: String, selectedSkillID: String? = nil, selectedSkillName: String? = nil) async throws -> PreparedSkillInstall {
        try await Task.detached(priority: .userInitiated) {
            try SkillOps.prepareInstall(
                source: source,
                selectedSkillID: selectedSkillID,
                selectedSkillName: selectedSkillName
            )
        }.value
    }

    /// 提交已经确认的安装内容，统一负责来源记录、反馈和刷新。
    func commitInstall(_ prepared: PreparedSkillInstall, enableIn: [AgentTarget]) async -> Bool {
        isBusy = true
        let store = storeDir
        let lockURL = lockFileURL
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SkillOps.commitPreparedInstall(
                    prepared,
                    storeDir: store,
                    enableTargets: enableIn,
                    lockFileURL: lockURL
                )
            }.value
            notice("已安装 \(result.installed.joined(separator: "、"))")
            isBusy = false
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            isBusy = false
            return false
        }
    }

    /// 下载并检查市场里的单个 skill，不写入本体库。
    func prepareMarketplaceInstall(skill: MarketplaceSkill) async throws -> PreparedSkillInstall {
        let source = "https://github.com/\(skill.source)"
        return try await prepareInstall(
            source: source,
            selectedSkillID: skill.skillID,
            selectedSkillName: skill.name
        )
    }

    /// 用户确认后提交市场安装。市场安装默认只进入本体库，启用平台留给详情页处理。
    func commitMarketplaceInstall(_ prepared: PreparedSkillInstall) async -> Bool {
        await commitInstall(prepared, enableIn: [])
    }

    // MARK: - 技能清单导出/导入

    /// 导出当前 skills 清单为 JSON 文件（换机/团队共享用）
    func exportManifest() {
        let manifest = SkillManifest.makeManifest(skills: skills, lockFile: lockFile)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "skillhub-manifest.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try manifest.write(to: url)
            notice("已导出 \(manifest.entries.count) 个 skills 的清单")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 从清单 JSON 导入：先预览（安装/启用/跳过计数），确认后在后台执行
    func importManifest() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try SkillManifest.load(from: url)
            let plan = SkillManifest.planImport(manifest: manifest, existingSkills: skills)
            guard !plan.isEmpty else {
                notice("清单中的 skills 均已就绪，无需导入")
                return
            }
            let alert = NSAlert()
            alert.messageText = "导入技能清单"
            alert.informativeText = "将安装 \(plan.installCount) 个，补启用 \(plan.enableCount) 项，跳过 \(plan.skipCount) 个。是否继续？"
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            isBusy = true
            let store = storeDir
            let currentTargets = targets
            Task.detached { [weak self] in
                let result = SkillManifest.executeImport(plan: plan, storeDir: store, targets: currentTargets)
                let summary = result.summary
                let detail = result.failed.isEmpty ? nil : result.failed.map { "\($0.name): \($0.error)" }.joined(separator: "\n")
                Task { @MainActor [weak self] in
                    self?.finishBusyOperation(message: summary, error: detail)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 更新检测

    /// 应用更新检测结果（MainActor 上调用；提取为方法以避免并发闭包捕获可变状态）
    private func applyUpdateResults(_ results: [String: UpdateChecker.UpdateInfo]) {
        for (skillID, info) in results {
            if let idx = skills.firstIndex(where: { $0.id == skillID }) {
                skills[idx].hasUpdate = info.hasUpdate
            }
        }
        updateChecking = false
        updateResults = results
        let updatable = results.values.filter(\.hasUpdate).count
        notice("检查完成，\(updatable) 个 skill 有更新")
    }

    func checkForUpdates() {
        guard !updateChecking else { return }
        let gitSkills = skills.filter { $0.gitRemote != nil }
        guard !gitSkills.isEmpty else {
            notice("没有来自 git 的 skill")
            return
        }

        updateChecking = true
        updateProgressDone = 0
        updateProgressTotal = gitSkills.count

        Task.detached { [weak self] in
            let results = UpdateChecker.checkAll(skills: gitSkills) { done, total in
                Task { @MainActor [weak self] in
                    self?.updateProgressDone = done
                    self?.updateProgressTotal = total
                }
            }
            Task { @MainActor [weak self] in
                self?.applyUpdateResults(results)
            }
        }
    }

    func pullUpdate(for skill: Skill) {
        do {
            try UpdateChecker.pull(skill: skill)
            notice("已更新 \(skill.name)")
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 供视图层使用的公开通知入口（带 3 秒自动消失）
    func postNotice(_ text: String) {
        notice(text)
    }

    /// 后台批量操作的统一收尾：关繁忙态、发通知、可选展示错误明细、刷新
    private func finishBusyOperation(message: String, error: String?) {
        isBusy = false
        notice(message)
        if let error { lastError = error }
        refresh()
    }

    private func notice(_ text: String) {
        lastNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if lastNotice == text { lastNotice = nil }
        }
    }
}
