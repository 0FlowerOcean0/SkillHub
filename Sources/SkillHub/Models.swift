import Foundation

// MARK: - Agent 目标（每个 agent 的 skills 目录）

struct AgentTarget: Identifiable, Hashable, Codable {
    let id: String          // 如 "qoder"
    let displayName: String // 如 "Qoder"
    let dir: URL

    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 内置已知 agent 生态；canonical 是 skill 本体推荐存放地
    static let canonicalID = "agents"

    static func builtin(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentTarget] {
        [
            AgentTarget(id: "agents", displayName: "本体库 (.agents)", dir: home.appendingPathComponent(".agents/skills")),
            AgentTarget(id: "qoder", displayName: "Qoder", dir: home.appendingPathComponent(".qoder/skills")),
            AgentTarget(id: "claude", displayName: "Claude Code", dir: home.appendingPathComponent(".claude/skills")),
            AgentTarget(id: "codex", displayName: "Codex", dir: home.appendingPathComponent(".codex/skills")),
            AgentTarget(id: "cursor", displayName: "Cursor", dir: home.appendingPathComponent(".cursor/skills")),
            AgentTarget(id: "iflow", displayName: "iFlow", dir: home.appendingPathComponent(".iflow/skills")),
        ]
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, dir
    }

    /// 目录去重键：标准化路径并去掉尾部斜杠，保证同一目录的不同写法视为同一个平台
    var directoryKey: String {
        var path = dir.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// 按实际目录去重：同一目录只保留先出现的 target（内置平台优先于自定义/自动检测）
    static func deduplicatedByDirectory(_ targets: [AgentTarget]) -> [AgentTarget] {
        var seen = Set<String>()
        var result: [AgentTarget] = []
        for target in targets where seen.insert(target.directoryKey).inserted {
            result.append(target)
        }
        return result
    }
}

// MARK: - Skill 在某个 agent 目录里的存在形式

enum PresenceKind: String {
    case real       // 真实目录（本体）
    case symlink    // 有效软链接
    case broken     // 断链
}

// MARK: - Skill 模型

struct Skill: Identifiable, Hashable {
    static func == (lhs: Skill, rhs: Skill) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 以本体（解析软链后）的绝对路径为唯一标识
    var id: String { canonicalPath.path }

    var name: String
    var descriptionText: String
    var version: String?
    var canonicalPath: URL
    /// agentID -> 存在形式
    var presence: [String: PresenceKind] = [:]
    var fileCount: Int = 0
    var sizeBytes: Int64 = 0
    var hasFrontmatter: Bool = false
    var tags: [String] = []
    var summary: String = ""
    var author: String = ""
    /// 存在的支持目录，如 references / scripts / assets
    var supportDirs: [String] = []
    /// Git 来源信息（用于更新检测）
    var gitRemote: String? = nil
    var gitBranch: String? = nil
    var gitLastCommit: String? = nil
    var hasUpdate: Bool = false
    /// 安全扫描报告（运行时缓存：来自 ScanCache 或后台扫描，避免每次刷新重扫全部文件）
    var securityReport: SecurityReport? = nil
    /// SKILL.md 全文（懒加载后缓存）
    var skillMarkdownPath: URL { canonicalPath.appendingPathComponent("SKILL.md") }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var hasAnalysis: Bool { !tags.isEmpty || !summary.isEmpty }
}

// MARK: - 体检问题

enum IssueSeverity: String, Comparable {
    case error, warning, info
    private var rank: Int { self == .error ? 0 : self == .warning ? 1 : 2 }
    static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool { lhs.rank < rhs.rank }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

// MARK: - 体检修复动作

enum FixAction: Equatable {
    case deleteBrokenLink(URL)
    case addFrontmatter(URL)
    case addDescription(URL, String)
    case renameDirectory(URL, String)
    case removeReference(URL, String)
    case enableInAgent(String, String)
    case migrateToStore(URL, String)   // 本体路径 + 来源 agent ID
    case none

    var label: String {
        switch self {
        case .deleteBrokenLink: return "删除断链"
        case .addFrontmatter: return "补 frontmatter"
        case .addDescription: return "补 description"
        case .renameDirectory: return "重命名目录"
        case .removeReference: return "移除引用"
        case .enableInAgent: return "启用到 agent"
        case .migrateToStore: return "迁移到本体库"
        case .none: return ""
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteBrokenLink, .removeReference, .migrateToStore: return true
        default: return false
        }
    }
}

struct DoctorIssue: Identifiable {
    let id = UUID()
    let severity: IssueSeverity
    let skillName: String?
    let title: String
    let detail: String
    var fixAction: FixAction = .none
    var hintActions: [HintAction] = []
}

enum HintAction: Identifiable {
    case revealInFinder(URL)
    case copyPath(String)

    var id: String { label + (url?.path ?? string ?? "") }

    var label: String {
        switch self {
        case .revealInFinder: return "在 Finder 中查看"
        case .copyPath: return "复制路径"
        }
    }

    var icon: String {
        switch self {
        case .revealInFinder: return "folder"
        case .copyPath: return "doc.on.doc"
        }
    }

    var url: URL? {
        if case .revealInFinder(let u) = self { return u }
        return nil
    }

    var string: String? {
        if case .copyPath(let s) = self { return s }
        return nil
    }
}

// MARK: - Skill Lock File (安装来源追踪)

struct SkillLockFile: Codable {
    let version: Int
    var skills: [String: SkillLockEntry]

    struct SkillLockEntry: Codable {
        var source: String?
        var sourceType: String?
        var sourceUrl: String?
        var skillPath: String?
        var skillFolderHash: String?
        var installedAt: Date?
        var updatedAt: Date?
        var ref: String?
    }

    static func load(from url: URL) -> SkillLockFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SkillLockFile.self, from: data)
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url)
    }
}
