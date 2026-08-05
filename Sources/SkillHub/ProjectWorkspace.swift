import Foundation

// MARK: - 模型

/// 注册的项目工作区：一个含有项目级 skills 目录的项目根目录。
struct ProjectWorkspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let path: URL
    let createdAt: Date

    init(id: UUID = UUID(), name: String? = nil, path: URL, createdAt: Date = Date()) {
        self.id = id
        self.name = name ?? path.lastPathComponent
        self.path = path
        self.createdAt = createdAt
    }

    /// 标准化路径（用于查重）：解析 . / ..、去掉末尾斜杠
    var normalizedPath: String {
        ProjectWorkspace.normalize(path)
    }

    static func normalize(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// 项目里发现的一个 skill 条目。
struct ProjectSkillEntry: Identifiable, Equatable {
    /// 稳定标识：发现位置 + 目录名（同一子目录下目录名唯一）
    var id: String { "\(source)/\(directoryName)" }

    /// frontmatter 里的 name，缺省为目录名
    let skillName: String
    /// 目录名（文件系统上的真实名字，同步时以此为准）
    let directoryName: String
    /// 发现位置的相对路径，如 ".claude/skills"
    let source: String
    /// skill 目录的绝对路径（已解析软链）
    let directory: URL

    let hasFrontmatter: Bool
    let descriptionText: String
    let version: String?
    let tags: [String]

    let fileCount: Int
    let sizeBytes: Int64

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - 错误

enum ProjectWorkspaceError: Error, Equatable, LocalizedError {
    case projectNotFound(String)
    case alreadyRegistered(String)
    case nameConflict(name: String, location: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let path):
            return "项目路径不存在：\(path)"
        case .alreadyRegistered(let path):
            return "该项目已注册：\(path)"
        case .nameConflict(let name, let location):
            return "目标位置已存在同名 skill「\(name)」：\(location)"
        }
    }
}

// MARK: - 持久化

/// 已注册项目列表的持久化（UserDefaults + JSON，风格同 SkillManager.favorites）。
/// 测试可注入独立 suite 的 UserDefaults 隔离数据。
final class ProjectWorkspaceStore {

    private let defaults: UserDefaults
    private let key = "projectWorkspaces"

    private(set) var workspaces: [ProjectWorkspace] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workspaces = Self.load(from: defaults, key: key)
    }

    /// 注册项目路径。按标准化路径查重，重复时抛 alreadyRegistered。
    @discardableResult
    func add(path: URL, name: String? = nil) throws -> ProjectWorkspace {
        let normalized = ProjectWorkspace.normalize(path)
        if workspaces.contains(where: { $0.normalizedPath == normalized }) {
            throw ProjectWorkspaceError.alreadyRegistered(normalized)
        }
        let ws = ProjectWorkspace(name: name, path: path)
        workspaces.append(ws)
        save()
        return ws
    }

    func remove(id: UUID) {
        workspaces.removeAll { $0.id == id }
        save()
    }

    func contains(path: URL) -> Bool {
        let normalized = ProjectWorkspace.normalize(path)
        return workspaces.contains { $0.normalizedPath == normalized }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(workspaces) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [ProjectWorkspace] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([ProjectWorkspace].self, from: data) else {
            return []
        }
        return list
    }
}

// MARK: - 发现扫描

/// 项目级 skills 目录的探测器。只在项目根目录下查约定位置，不递归整个项目。
enum ProjectScanner {

    /// 约定的 skills 子目录（相对项目根）
    static let knownSkillDirs: [String] = [
        ".claude/skills",
        ".agents/skills",
        ".codex/skills",
        ".cursor/skills",
        ".qoder/skills",
        ".iflow/skills",
    ]

    /// 扫描项目里的所有约定 skills 目录。
    /// 项目路径不存在时抛 projectNotFound。
    /// 约定目录本身不存在时跳过（不是错误）；目录里没有 SKILL.md 的子项忽略。
    static func scan(workspace: ProjectWorkspace) throws -> [ProjectSkillEntry] {
        let fm = FileManager.default
        let root = workspace.path
        var isDir: ObjCBool = false
        // fileExists 会跟随软链，能覆盖项目根本身是软链的情况
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectWorkspaceError.projectNotFound(root.path)
        }

        var entries: [ProjectSkillEntry] = []

        for subdir in knownSkillDirs {
            let skillsDir = root.appendingPathComponent(subdir, isDirectory: true)
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: skillsDir.path, isDirectory: &subIsDir), subIsDir.boolValue else {
                continue
            }

            let children = (try? fm.contentsOfDirectory(
                at: skillsDir,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                // 解析软链后要求：是目录且含 SKILL.md
                let resolved = child.resolvingSymlinksInPath()
                var childIsDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &childIsDir), childIsDir.boolValue else {
                    continue
                }
                guard fm.fileExists(atPath: resolved.appendingPathComponent("SKILL.md").path) else {
                    continue
                }
                entries.append(makeEntry(directory: resolved, source: subdir))
            }
        }

        return entries.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.directoryName.localizedCaseInsensitiveCompare($1.directoryName) == .orderedAscending
        }
    }

    private static func makeEntry(directory: URL, source: String) -> ProjectSkillEntry {
        let fm = FileManager.default
        let fmr = FrontmatterParser.parse(fileURL: directory.appendingPathComponent("SKILL.md"))

        var count = 0
        var size: Int64 = 0
        if let en = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    count += 1
                    size += Int64(v?.fileSize ?? 0)
                }
            }
        }

        return ProjectSkillEntry(
            skillName: fmr.name ?? directory.lastPathComponent,
            directoryName: directory.lastPathComponent,
            source: source,
            directory: directory,
            hasFrontmatter: fmr.hasFrontmatter,
            descriptionText: fmr.descriptionText ?? "",
            version: fmr.version,
            tags: fmr.tags,
            fileCount: count,
            sizeBytes: size
        )
    }
}

// MARK: - 双向同步

/// 项目 ↔ 本体库 的复制逻辑（只复制，不移动；同名冲突时报错不覆盖）。
enum ProjectSync {

    /// 把项目里的 skill 复制进本体库。
    /// - Returns: 本体库中新建的目录 URL
    /// - Throws: nameConflict（本体库已有同名目录）、projectNotFound（源已消失）或文件系统错误
    @discardableResult
    static func importToStore(entry: ProjectSkillEntry, workspace: ProjectWorkspace, storeDir: URL) throws -> URL {
        let fm = FileManager.default
        let source = entry.directory
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw ProjectWorkspaceError.projectNotFound(source.path)
        }
        let dest = storeDir.appendingPathComponent(entry.directoryName, isDirectory: true)
        guard !fm.fileExists(atPath: dest.path) else {
            throw ProjectWorkspaceError.nameConflict(name: entry.directoryName, location: dest.path)
        }
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// 把本体库 skill 复制到项目指定子目录（默认 ".claude/skills"）。
    /// - Returns: 项目中新建的目录 URL
    /// - Throws: nameConflict（项目里已有同名目录）、projectNotFound（项目根或源不存在）或文件系统错误
    @discardableResult
    static func exportToProject(
        skillCanonicalPath: URL,
        workspace: ProjectWorkspace,
        subdir: String = ".claude/skills"
    ) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workspace.path.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectWorkspaceError.projectNotFound(workspace.path.path)
        }
        guard fm.fileExists(atPath: skillCanonicalPath.appendingPathComponent("SKILL.md").path) else {
            throw ProjectWorkspaceError.projectNotFound(skillCanonicalPath.path)
        }

        let name = skillCanonicalPath.lastPathComponent
        let skillsDir = workspace.path.appendingPathComponent(subdir, isDirectory: true)
        let dest = skillsDir.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: dest.path) else {
            throw ProjectWorkspaceError.nameConflict(name: name, location: dest.path)
        }
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try fm.copyItem(at: skillCanonicalPath, to: dest)
        return dest
    }
}
