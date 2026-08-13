import Foundation

/// 单个 skill 的缓存条目：扫描结果 + 指纹。
/// 指纹 = SKILL.md 修改时间 + skill 目录修改时间；任一变化即触发该 skill 重扫。
/// 注意：只修改 skill 目录内既有文件（不增删文件、不动 SKILL.md）不会改变目录 mtime，
/// 此时文件数/体积可能短暂滞后，手动「刷新」（force）可拿到最新值。
struct CachedSkillEntry: Codable {
    var fingerprint: String
    var name: String
    var descriptionText: String
    var version: String?
    var fileCount: Int
    var sizeBytes: Int64
    var hasFrontmatter: Bool
    var hasSkillMarkdown: Bool?
    var tags: [String]
    var summary: String
    var author: String
    var supportDirs: [String]
    var gitRemote: String?
    var gitBranch: String?
    var gitLastCommit: String?
    /// 安全扫描结果（可选：旧版缓存没有此字段，解码为 nil 后由后台补扫）
    var securityFindings: [SecurityFinding]?
    var securityScore: Int?

    init(skill: Skill, fingerprint: String) {
        self.fingerprint = fingerprint
        self.name = skill.name
        self.descriptionText = skill.descriptionText
        self.version = skill.version
        self.fileCount = skill.fileCount
        self.sizeBytes = skill.sizeBytes
        self.hasFrontmatter = skill.hasFrontmatter
        self.hasSkillMarkdown = skill.hasSkillMarkdown
        self.tags = skill.tags
        self.summary = skill.summary
        self.author = skill.author
        self.supportDirs = skill.supportDirs
        self.gitRemote = skill.gitRemote
        self.gitBranch = skill.gitBranch
        self.gitLastCommit = skill.gitLastCommit
        self.securityFindings = skill.securityReport?.findings
        self.securityScore = skill.securityReport?.score
    }

    func makeReport() -> SecurityReport? {
        guard let findings = securityFindings, let score = securityScore else { return nil }
        return SecurityReport(findings: findings, score: score)
    }

    /// 从缓存还原 Skill（presence 由每次扫描的目录列举重新填充，不进缓存）
    func makeSkill(canonicalPath: URL) -> Skill {
        var skill = Skill(
            name: name,
            descriptionText: descriptionText,
            version: version,
            canonicalPath: canonicalPath
        )
        skill.fileCount = fileCount
        skill.sizeBytes = sizeBytes
        skill.hasFrontmatter = hasFrontmatter
        skill.hasSkillMarkdown = hasSkillMarkdown ?? true
        skill.tags = tags
        skill.summary = summary
        skill.author = author
        skill.supportDirs = supportDirs
        skill.gitRemote = gitRemote
        skill.gitBranch = gitBranch
        skill.gitLastCommit = gitLastCommit
        skill.securityReport = makeReport()
        return skill
    }
}

/// 扫描结果磁盘缓存。启动时先读缓存，逐 skill 比对指纹，
/// 全部命中则跳过解析 frontmatter / git 子进程，界面秒开。
struct ScanCache: Codable {
    static let formatVersion = 1

    var version: Int
    /// canonicalPath -> 缓存条目
    var entries: [String: CachedSkillEntry]

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/.skillhub-scan-cache.json")
    }

    static func load(from url: URL = ScanCache.defaultURL) -> ScanCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ScanCache.self, from: data),
              cache.version == formatVersion else { return nil }
        return cache
    }

    func save(to url: URL = ScanCache.defaultURL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
