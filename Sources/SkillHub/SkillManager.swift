import Foundation

/// 智能管家：来源分析、跨平台同步、使用频率、批量操作
struct SkillManager {

    // MARK: - 来源分组

    struct SourceGroup: Identifiable {
        let id = UUID()
        let source: String           // GitHub 仓库名
        let sourceUrl: String?
        let skills: [Skill]
        let installedAt: Date?

        var displayName: String {
            source.isEmpty ? "手动安装" : source
        }
    }

    /// 按 GitHub 仓库分组 skills
    static func groupBySource(skills: [Skill], lockFile: SkillLockFile?) -> [SourceGroup] {
        var groups: [String: [Skill]] = [:]
        var sourceUrls: [String: String] = [:]
        var installDates: [String: Date] = [:]

        for skill in skills {
            let source: String
            if let lock = lockFile?.skills[skill.name] {
                source = lock.source ?? "unknown"
                if let url = lock.sourceUrl { sourceUrls[source] = url }
                if let date = lock.installedAt { installDates[source] = date }
            } else {
                source = ""
            }
            groups[source, default: []].append(skill)
        }

        return groups.map { SourceGroup(
            source: $0.key,
            sourceUrl: sourceUrls[$0.key],
            skills: $0.value,
            installedAt: installDates[$0.key]
        )}.sorted { $0.skills.count > $1.skills.count }
    }

    // MARK: - 跨平台分析

    struct PlatformCoverage: Identifiable {
        let id = UUID()
        let agentId: String
        let agentName: String
        let enabled: Int
        let missing: [Skill]
        let total: Int
        var percentage: Double { total == 0 ? 0 : Double(enabled) / Double(total) }
    }

    /// 分析每个平台的覆盖率
    static func analyzeCoverage(skills: [Skill], targets: [AgentTarget]) -> [PlatformCoverage] {
        targets.filter(\.exists).compactMap { target in
            guard target.id != AgentTarget.canonicalID else { return nil }
            let enabled = skills.filter { $0.presence[target.id] != nil }
            let missing = skills.filter { $0.presence[target.id] == nil }
            return PlatformCoverage(
                agentId: target.id,
                agentName: target.displayName,
                enabled: enabled.count,
                missing: missing,
                total: skills.count
            )
        }
    }

    // MARK: - 使用频率推断

    struct UsageInfo {
        let skill: Skill
        let lastModified: Date?
        let daysSinceModified: Int?
        let category: UsageCategory
    }

    enum UsageCategory: String {
        case active = "活跃"
        case idle = "闲置"
        case dormant = "休眠"
        case unknown = "未知"

        var color: String {
            switch self {
            case .active: return "green"
            case .idle: return "orange"
            case .dormant: return "red"
            case .unknown: return "gray"
            }
        }
    }

    /// 基于文件修改时间推断使用频率
    static func analyzeUsage(skills: [Skill]) -> [UsageInfo] {
        let calendar = Calendar.current
        let now = Date()

        return skills.map { skill in
            let modDate = modificationDate(of: skill.canonicalPath)
            var days: Int? = nil
            var category: UsageCategory = .unknown

            if let modDate = modDate {
                days = calendar.dateComponents([.day], from: modDate, to: now).day
                if let d = days {
                    switch d {
                    case ...7: category = .active   // 负数（修改时间在未来）也视为活跃
                    case 8...30: category = .idle
                    default: category = .dormant
                    }
                }
            }

            return UsageInfo(
                skill: skill,
                lastModified: modDate,
                daysSinceModified: days,
                category: category
            )
        }.sorted { ($0.daysSinceModified ?? 999) < ($1.daysSinceModified ?? 999) }
    }

    // MARK: - 冗余检测

    struct RedundancyGroup: Identifiable {
        let id = UUID()
        let reason: String
        let skills: [Skill]
        let suggestion: String
    }

    /// 检测可能冗余的 skills
    static func detectRedundancy(skills: [Skill]) -> [RedundancyGroup] {
        var groups: [RedundancyGroup] = []

        // 1. 同名不同路径
        var byName: [String: [Skill]] = [:]
        for skill in skills { byName[skill.name.lowercased(), default: []].append(skill) }
        for (_, group) in byName where group.count > 1 {
            groups.append(RedundancyGroup(
                reason: "同名 skill",
                skills: group,
                suggestion: "保留描述最完整的版本，删除其他"
            ))
        }

        // 2. 功能相似（基于标签重叠）
        let tagged = skills.filter { !$0.tags.isEmpty }
        var used = Set<String>()
        for i in 0..<tagged.count {
            guard !used.contains(tagged[i].id) else { continue }
            var similar = [tagged[i]]
            for j in (i+1)..<tagged.count {
                guard !used.contains(tagged[j].id) else { continue }
                let overlap = Set(tagged[i].tags).intersection(Set(tagged[j].tags))
                if overlap.count >= 2 {
                    similar.append(tagged[j])
                    used.insert(tagged[j].id)
                }
            }
            if similar.count > 1 {
                used.insert(tagged[i].id)
                groups.append(RedundancyGroup(
                    reason: "标签高度重叠（\(Set(similar.flatMap(\.tags)).joined(separator: ", "))）",
                    skills: similar,
                    suggestion: "考虑合并为一个综合 skill"
                ))
            }
        }

        return groups
    }

    // MARK: - 清理建议

    struct CleanupSuggestion: Identifiable {
        let id = UUID()
        let skill: Skill
        let reason: String
        let action: CleanupAction
    }

    enum CleanupAction {
        case delete
        case disable(agentId: String)
        case migrate
    }

    /// 生成清理建议
    static func suggestCleanup(skills: [Skill], targets: [AgentTarget], issues: [DoctorIssue]) -> [CleanupSuggestion] {
        var suggestions: [CleanupSuggestion] = []

        for skill in skills {
            // 大文件
            if skill.sizeBytes > 50 * 1024 * 1024 {
                suggestions.append(CleanupSuggestion(
                    skill: skill,
                    reason: "体积过大（\(skill.sizeDisplay)），可能包含不必要的资产",
                    action: .delete
                ))
            }

            // 休眠超过 90 天
            if let modDate = modificationDate(of: skill.canonicalPath) {
                let days = Calendar.current.dateComponents([.day], from: modDate, to: Date()).day ?? 0
                if days > 90 {
                    suggestions.append(CleanupSuggestion(
                        skill: skill,
                        reason: "\(days) 天未修改，可能不再使用",
                        action: .delete
                    ))
                }
            }

            // 本体不在 canonical store（库内有软链指向同一本体的视为已收纳，不建议迁移）
            let canonicalStore = targets.first(where: { $0.id == AgentTarget.canonicalID })?.dir
            if let store = canonicalStore, !isRepresentedInStore(skill: skill, storeDir: store) {
                suggestions.append(CleanupSuggestion(
                    skill: skill,
                    reason: "本体不在本体库，管理不便",
                    action: .migrate
                ))
            }
        }

        return suggestions
    }

    // MARK: - 批量操作

    /// 批量启用 skill 到多个平台
    static func batchEnable(skill: Skill, to targets: [AgentTarget]) -> (success: Int, failed: [(String, String)]) {
        var success = 0
        var failed: [(String, String)] = []

        for target in targets where target.id != AgentTarget.canonicalID {
            do {
                if skill.presence[target.id] == nil {
                    try SkillOps.enable(skill: skill, in: target)
                    success += 1
                }
            } catch {
                failed.append((target.displayName, error.localizedDescription))
            }
        }
        return (success, failed)
    }

    /// 批量禁用 skill 从多个平台
    static func batchDisable(skill: Skill, from targets: [AgentTarget]) -> (success: Int, failed: [(String, String)]) {
        var success = 0
        var failed: [(String, String)] = []

        for target in targets where target.id != AgentTarget.canonicalID {
            do {
                if skill.presence[target.id] != nil {
                    try SkillOps.disable(skill: skill, in: target)
                    success += 1
                }
            } catch {
                failed.append((target.displayName, error.localizedDescription))
            }
        }
        return (success, failed)
    }

    /// 同步 skill 到所有平台
    static func syncToAll(skill: Skill, targets: [AgentTarget]) -> (success: Int, failed: [(String, String)]) {
        batchEnable(skill: skill, to: targets)
    }

    // MARK: - 智能分类

    enum SkillCategory: String, CaseIterable, Identifiable {
        case writing = "写作与文档"
        case coding = "编码与开发"
        case data = "数据与分析"
        case communication = "沟通与协作"
        case creative = "创意与设计"
        case other = "其他"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .writing: return "doc.text"
            case .coding: return "chevron.left.forwardslash.chevron.right"
            case .data: return "chart.bar"
            case .communication: return "bubble.left.and.bubble.right"
            case .creative: return "paintbrush"
            case .other: return "folder"
            }
        }
        var color: String {
            switch self {
            case .writing: return "blue"
            case .coding: return "purple"
            case .data: return "green"
            case .communication: return "orange"
            case .creative: return "pink"
            case .other: return "gray"
            }
        }
    }

    struct CategorizedSkills: Identifiable {
        let id = UUID()
        let category: SkillCategory
        let skills: [Skill]
    }

    // MARK: - 作者分组

    struct AuthorGroup: Identifiable {
        let id = UUID()
        let author: String    // 空字符串表示"未知作者"；"其他"组为 miscAuthorGroupID
        let skills: [Skill]
        let isMisc: Bool      // true 表示"其他"归并组（包含多个 skill 数不足阈值的作者）

        var displayName: String {
            if isMisc { return "其他" }
            return author.isEmpty ? "未知作者" : author
        }
    }

    /// 作者单独成组所需的最少 skill 数，不足的统一归并进"其他"组
    static let authorGroupMinCount = 3

    /// "其他"组的选中标识（不可能与真实作者名冲突，也不会被 author 精确匹配命中）
    static let miscAuthorGroupID = "__misc_authors__"

    /// 按作者分组 skills：≥ authorGroupMinCount 的作者单独成组，不足的统一归并进"其他"组，
    /// 未知作者（空串）始终单独成组。排序：普通作者（字母序）< "其他" < "未知作者"
    static func groupByAuthor(skills: [Skill]) -> [AuthorGroup] {
        var groups: [String: [Skill]] = [:]
        for skill in skills {
            let key = skill.author
            groups[key, default: []].append(skill)
        }

        var result: [AuthorGroup] = []
        var miscSkills: [Skill] = []
        for (author, authorSkills) in groups {
            if !author.isEmpty && authorSkills.count < authorGroupMinCount {
                miscSkills.append(contentsOf: authorSkills)
            } else {
                result.append(AuthorGroup(author: author, skills: authorSkills, isMisc: false))
            }
        }
        if !miscSkills.isEmpty {
            miscSkills.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            result.append(AuthorGroup(author: miscAuthorGroupID, skills: miscSkills, isMisc: true))
        }

        return result.sorted { lhs, rhs in
            // 排序层级：普通作者组 0 < "其他"组 1 < "未知作者"组 2
            func rank(_ group: AuthorGroup) -> Int {
                if group.isMisc { return 1 }
                return group.author.isEmpty ? 2 : 0
            }
            let (lr, rr) = (rank(lhs), rank(rhs))
            if lr != rr { return lr < rr }
            // 普通作者组按 skill 数量降序（高产作者优先），数量相同再按名称字母序
            if lr == 0 && lhs.skills.count != rhs.skills.count {
                return lhs.skills.count > rhs.skills.count
            }
            return lhs.author.localizedCaseInsensitiveCompare(rhs.author) == .orderedAscending
        }
    }

    /// 基于 skill 名称和描述自动分类
    static func categorize(skills: [Skill]) -> [CategorizedSkills] {
        var categorized: [SkillCategory: [Skill]] = [:]
        for category in SkillCategory.allCases { categorized[category] = [] }

        for skill in skills {
            let category = categorizeSkill(skill)
            categorized[category]?.append(skill)
        }

        return SkillCategory.allCases.compactMap { category in
            guard let skills = categorized[category], !skills.isEmpty else { return nil }
            return CategorizedSkills(category: category, skills: skills.sorted { $0.name < $1.name })
        }
    }

    private static func categorizeSkill(_ skill: Skill) -> SkillCategory {
        let name = skill.name.lowercased()
        let desc = skill.descriptionText.lowercased()
        let tags = skill.tags.map { $0.lowercased() }
        let text = "\(name) \(desc) \(tags.joined(separator: " "))"

        // 写作与文档
        if text.containsAny(["write", "writing", "draft", "document", "doc", "markdown", "blog",
                            "article", "essay", "translate", "translation", "summarize", "summary",
                            "写", "文章", "文档", "翻译", "总结", "草稿", "笔记"]) {
            return .writing
        }

        // 编码与开发
        if text.containsAny(["code", "coding", "debug", "test", "review", "refactor", "git",
                            "api", "sdk", "cli", "script", "automat", "lint", "format",
                            "编程", "代码", "调试", "测试", "审查", "重构", "脚本", "自动化"]) {
            return .coding
        }

        // 数据与分析
        if text.containsAny(["data", "analy", "chart", "graph", "visual", "research", "report",
                            "statist", "metric", "dashboard", "crawl", "scrape",
                            "数据", "分析", "图表", "可视化", "研究", "报告", "统计", "爬虫"]) {
            return .data
        }

        // 沟通与协作
        if text.containsAny(["email", "mail", "message", "chat", "slack", "wechat", "lark",
                            "feishu", "meeting", "calendar", "schedule", "task", "project",
                            "邮件", "消息", "聊天", "会议", "日历", "任务", "项目", "协作"]) {
            return .communication
        }

        // 创意与设计
        if text.containsAny(["design", "image", "photo", "video", "audio", "music", "art",
                            "creative", "ui", "ux", "prototype", "mockup", "brand",
                            "设计", "图像", "照片", "视频", "音频", "音乐", "创意", "原型"]) {
            return .creative
        }

        return .other
    }

    // MARK: - 搜索增强

    struct SearchResult: Identifiable {
        let id = UUID()
        let skill: Skill
        let score: Double  // 匹配度 0-1
        let matchReason: String
    }

    /// 智能搜索：支持模糊匹配和多字段搜索
    static func search(skills: [Skill], query: String) -> [SearchResult] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return skills.map { SearchResult(skill: $0, score: 0.5, matchReason: "") } }

        var results: [SearchResult] = []

        for skill in skills {
            var score: Double = 0
            var reasons: [String] = []

            // 精确名称匹配 (最高优先级)
            if skill.name.lowercased() == q {
                score = 1.0
                reasons.append("精确匹配")
            }
            // 名称包含（前缀已被包含覆盖，不设单独分支）
            else if skill.name.lowercased().contains(q) {
                score = 0.9
                reasons.append("名称匹配")
            }
            // 描述包含
            else if skill.descriptionText.lowercased().contains(q) {
                score = 0.7
                reasons.append("描述匹配")
            }
            // 标签匹配
            else if skill.tags.contains(where: { $0.lowercased().contains(q) }) {
                score = 0.6
                reasons.append("标签匹配")
            }
            // 作者匹配
            else if !skill.author.isEmpty && skill.author.lowercased().contains(q) {
                score = 0.55
                reasons.append("作者匹配")
            }
            // 模糊匹配（字符顺序）
            else if fuzzyMatch(text: skill.name.lowercased(), query: q) {
                score = 0.4
                reasons.append("模糊匹配")
            }
            // 描述模糊匹配
            else if fuzzyMatch(text: skill.descriptionText.lowercased(), query: q) {
                score = 0.3
                reasons.append("描述模糊")
            }

            if score > 0 {
                results.append(SearchResult(
                    skill: skill,
                    score: score,
                    matchReason: reasons.joined(separator: ", ")
                ))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// 模糊匹配：检查 query 是否按顺序作为子序列出现在 text 中
    private static func fuzzyMatch(text: String, query: String) -> Bool {
        if query.isEmpty { return true }
        var textIndex = text.startIndex
        for char in query {
            var found = false
            while textIndex < text.endIndex {
                let current = text[textIndex]
                textIndex = text.index(after: textIndex)
                if current == char {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    // MARK: - 收藏夹

    private static let favoritesKey = "favoriteSkills"

    static var favorites: [String] {
        get {
            (UserDefaults.standard.string(forKey: favoritesKey) ?? "")
                .split(separator: "\n")
                .map(String.init)
        }
        set {
            UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: favoritesKey)
        }
    }

    static func toggleFavorite(_ skill: Skill) {
        var favs = favorites
        if favs.contains(skill.name) {
            favs.removeAll { $0 == skill.name }
        } else {
            favs.append(skill.name)
        }
        favorites = favs
    }

    static func isFavorite(_ skill: Skill) -> Bool {
        favorites.contains(skill.name)
    }

    // MARK: - 工具函数

    /// 判断 path 是否位于 directory 之内（按路径组件比较，避免 "skills2" 误判为 "skills" 的子路径）
    static func isPath(_ path: URL, inside directory: URL) -> Bool {
        let dirPath = directory.standardizedFileURL.path
        let childPath = path.standardizedFileURL.path
        return childPath == dirPath || childPath.hasPrefix(dirPath.hasSuffix("/") ? dirPath : dirPath + "/")
    }

    /// 本体是否已被本体库"收纳"：本体直接在库内，或库内同名入口（软链）解析后指向同一本体。
    /// 后者常见于本体放在 iCloud 等外部目录、本体库用软链登记的情况——视为已收纳，不算散落。
    static func isRepresentedInStore(skill: Skill, storeDir: URL) -> Bool {
        if isPath(skill.canonicalPath, inside: storeDir) { return true }
        let entry = storeDir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
        guard FileManager.default.fileExists(atPath: entry.path) else { return false }
        return entry.resolvingSymlinksInPath().standardizedFileURL.path
            == skill.canonicalPath.standardizedFileURL.path
    }

    static func modificationDate(of url: URL) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var latest: Date?
        for case let fileURL as URL in enumerator {
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let modDate = attrs[.modificationDate] as? Date {
                if latest == nil || modDate > latest! {
                    latest = modDate
                }
            }
        }
        return latest
    }
}

// MARK: - String 扩展

extension String {
    func containsAny(_ keywords: [String]) -> Bool {
        keywords.contains { self.contains($0) }
    }
}
