import Foundation
import AppKit
import CryptoKit

enum SkillOpsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// 启用（上架到平台目录）的方式：相对软链（默认）或实体复制
enum LinkMode {
    case symlink
    case copy
}

/// 下载并冻结在临时目录中的安装内容。只有用户确认后才会写入本体库。
struct PreparedSkillInstall: Identifiable {
    struct Item: Identifiable {
        var id: String { sourceDirectory.path }
        let sourceDirectory: URL
        let directoryName: String
        let name: String
        let descriptionText: String
        let skillPath: String
        let fileCount: Int
        let sizeBytes: Int64
        let files: [String]
        let folderHash: String
        let securityReport: SecurityReport
        let validationWarnings: [String]

        var sizeDisplay: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    let id = UUID()
    let source: String
    let sourceType: String
    let sourceURL: String?
    let requestedRef: String?
    let resolvedCommit: String?
    let stagingRoot: URL
    let items: [Item]
    let skippedSkillNames: [String]
}

struct SkillInstallRecord {
    let skillName: String
    let source: String
    let sourceType: String
    let sourceURL: String?
    let skillPath: String
    let folderHash: String
    let installedAt: Date
    let resolvedRef: String?
    let resolvedCommit: String?
}

struct SkillInstallResult {
    let installed: [String]
    let resolvedRef: String?
    let resolvedCommit: String?
    let records: [SkillInstallRecord]
}

/// 管理（启用/禁用/删除）、安装（GitHub / 本地）、调用（复制提示词 / 打开）
enum SkillOps {

    private static let gitTimeout: TimeInterval = 120

    struct GitInstallSource {
        let repository: String
        let subPath: String?
        let ref: String?
    }

    // MARK: - 启用 / 禁用

    /// copy 模式副本里的标记文件名：disable 靠它区分「复制产生的副本」与「本体」
    static let copyMarkerName = ".skillhub-copy"

    /// 在指定 agent 目录启用 skill：默认创建指向本体的相对软链接；
    /// mode 为 .copy 时把本体完整复制到平台目录（副本内写入 .skillhub-copy 标记）。
    /// 目标已存在同名条目时两种模式都报错，行为语义一致。
    static func enable(skill: Skill, in target: AgentTarget, mode: LinkMode = .symlink) throws {
        let fm = FileManager.default
        if !target.exists {
            try fm.createDirectory(at: target.dir, withIntermediateDirectories: true)
        }
        let linkPath = target.dir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
        if fm.fileExists(atPath: linkPath.path) || (try? fm.destinationOfSymbolicLink(atPath: linkPath.path)) != nil {
            throw SkillOpsError.message("\(target.displayName) 里已存在同名条目：\(linkPath.lastPathComponent)")
        }
        switch mode {
        case .symlink:
            let relative = relativePath(from: target.dir, to: skill.canonicalPath)
            try fm.createSymbolicLink(atPath: linkPath.path, withDestinationPath: relative)
        case .copy:
            try fm.copyItem(at: skill.canonicalPath, to: linkPath)
            // 写入副本标记，供 disable 识别这是可复制后删除的副本而非本体
            try "skillhub copy\n".write(to: linkPath.appendingPathComponent(copyMarkerName),
                                        atomically: true, encoding: .utf8)
        }
    }

    /// 移除软链接或 copy 模式产生的副本；本体目录绝不通过 disable 删除
    static func disable(skill: Skill, in target: AgentTarget) throws {
        let fm = FileManager.default
        let entry = target.dir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
        // 软链：直接删
        if (try? fm.destinationOfSymbolicLink(atPath: entry.path)) != nil {
            try fm.removeItem(at: entry)
            return
        }
        // 真实目录：带 .skillhub-copy 标记的是 copy 模式副本，允许删除；
        // 无标记的按本体处理，照旧拒绝
        guard fm.fileExists(atPath: entry.appendingPathComponent(copyMarkerName).path) else {
            throw SkillOpsError.message("\(entry.lastPathComponent) 在 \(target.displayName) 里是真实目录（本体），不会自动删除。请先迁移本体。")
        }
        try fm.removeItem(at: entry)
    }

    /// 删除本体：先清理各 agent 目录里的同名条目，再把本体移入废纸篓。
    /// 同名条目按类型处理：解析回本体的软链 → 删；带 .skillhub-copy 标记的
    /// copy 副本 → 删；无标记的真实目录 → 跳过（可能是独立本体，保护不删）。
    static func trash(skill: Skill, targets: [AgentTarget]) throws {
        let fm = FileManager.default
        for t in targets {
            let entry = t.dir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
            // 软链：只删解析回本体的（指向别处的同名软链不动）
            if (try? fm.destinationOfSymbolicLink(atPath: entry.path)) != nil {
                if entry.resolvingSymlinksInPath().path == skill.canonicalPath.path {
                    try? fm.removeItem(at: entry)
                }
                continue
            }
            // 真实目录：带 copy 标记的是副本，随本体一起清理；
            // 无标记的按本体保护跳过（注意 canonical 本身在平台目录里时也会命中这里，必须跳过）
            if fm.fileExists(atPath: entry.appendingPathComponent(copyMarkerName).path) {
                try? fm.removeItem(at: entry)
            }
        }
        try fm.trashItem(at: skill.canonicalPath, resultingItemURL: nil)
    }

    static func removeBrokenLink(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - 体检修复

    /// 为缺少 frontmatter 的 SKILL.md 补上基本 frontmatter
    static func addFrontmatter(to fileURL: URL) throws {
        var text = try String(contentsOf: fileURL, encoding: .utf8)
        let name = fileURL.deletingLastPathComponent().lastPathComponent
        let frontmatter = "---\nname: \"\(name)\"\ndescription: \"\"\n---\n\n"
        text = frontmatter + text
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 为空 description 补一个占位描述
    static func addDescription(to fileURL: URL, description: String) throws {
        var text = try String(contentsOf: fileURL, encoding: .utf8)
        // 在 name: 行后面插入 description
        var lines = text.components(separatedBy: .newlines)
        if let nameIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:") }) {
            let indent = String(lines[nameIdx].prefix(while: { $0 == " " }))
            lines.insert("\(indent)description: \"\(description)\"", at: nameIdx + 1)
            text = lines.joined(separator: "\n")
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// 重命名 skill 目录（同时更新 frontmatter 里的 name）
    static func renameDirectory(from oldURL: URL, to newName: String) throws {
        let parent = oldURL.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            throw SkillOpsError.message("目标目录已存在：\(newURL.path)")
        }
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        // 更新 frontmatter 里的 name（只改 frontmatter 块内的 name 行，支持有/无引号两种写法）
        let md = newURL.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: md.path),
           var text = try? String(contentsOf: md, encoding: .utf8) {
            var lines = text.components(separatedBy: "\n")
            if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
               let end = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                for idx in 1..<end {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("name:") || t.hasPrefix("name :") else { continue }
                    let indent = String(lines[idx].prefix(while: { $0 == " " }))
                    lines[idx] = "\(indent)name: \"\(newName)\""
                    break
                }
                text = lines.joined(separator: "\n")
                try text.write(to: md, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 从 SKILL.md 里移除对不存在文件的引用行
    static func removeReference(from fileURL: URL, reference: String) throws {
        var text = try String(contentsOf: fileURL, encoding: .utf8)
        // 移除包含该引用的行
        text = text.components(separatedBy: .newlines)
            .filter { !$0.contains(reference) }
            .joined(separator: "\n")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 把 skill 启用（创建软链接）到指定 agent
    static func enableInAgent(skillPath: String, agentID: String) throws {
        let url = URL(fileURLWithPath: skillPath)
        let target = AgentTarget.builtin().first(where: { $0.id == agentID })
        guard let target else { throw SkillOpsError.message("未知 agent：\(agentID)") }
        let skill = Skill(
            name: url.lastPathComponent,
            descriptionText: "",
            canonicalPath: url
        )
        try enable(skill: skill, in: target)
    }

    /// 批量修复
    static func fixAll(_ issues: [DoctorIssue], targets: [AgentTarget]) -> (fixed: Int, failed: [(String, String)]) {
        var fixed = 0
        var failed: [(String, String)] = []

        for issue in issues {
            do {
                switch issue.fixAction {
                case .deleteBrokenLink(let url):
                    try removeBrokenLink(at: url)
                case .addFrontmatter(let url):
                    try addFrontmatter(to: url)
                case .addDescription(let url, let desc):
                    try addDescription(to: url, description: desc)
                case .renameDirectory(let url, let name):
                    try renameDirectory(from: url, to: name)
                case .removeReference(let url, let ref):
                    try removeReference(from: url, reference: ref)
                case .enableInAgent(let path, let agentID):
                    try enableInAgent(skillPath: path, agentID: agentID)
                case .migrateToStore(let path, let agentID):
                    let store = targets.first(where: { $0.id == AgentTarget.canonicalID })?.dir
                        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills")
                    try migrateToStore(skillPath: path, agentID: agentID, storeDir: store)
                case .none:
                    continue
                }
                fixed += 1
            } catch {
                failed.append((issue.title, error.localizedDescription))
            }
        }
        return (fixed, failed)
    }

    /// 把本体从非标准位置迁移到 canonical 本体库，并在原 agent 目录建软链
    static func migrateToStore(skillPath: URL, agentID: String, storeDir: URL) throws {
        try migrateToStore(skillPath: skillPath, target: AgentTarget.builtin().first(where: { $0.id == agentID }), storeDir: storeDir)
    }

    /// 把本体迁移到本体库，并在原平台目录建软链（支持任意 AgentTarget；target 为 nil 时只移动不建链）
    static func migrateToStore(skillPath: URL, target: AgentTarget?, storeDir: URL) throws {
        let fm = FileManager.default
        let src = skillPath
        let name = src.lastPathComponent
        let dest = storeDir.appendingPathComponent(name)

        guard fm.fileExists(atPath: src.path) else {
            throw SkillOpsError.message("源目录不存在：\(src.path)")
        }
        guard !fm.fileExists(atPath: dest.path) else {
            throw SkillOpsError.message("本体库已存在同名 skill：\(name)")
        }

        // 移动本体到本体库
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dest)

        // 在原平台目录建软链
        if let target {
            if !target.exists { try? fm.createDirectory(at: target.dir, withIntermediateDirectories: true) }
            let link = target.dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: link.path) {
                let rel = relativePath(from: target.dir, to: dest)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: rel)
            }
        }
    }

    /// 收编遇到同名冲突时的"链接化"处理：散落的真实目录移入废纸篓（可恢复），
    /// 原地改建指向本体库同名版本的软链
    static func relinkToStore(skillPath: URL, target: AgentTarget?, storeDir: URL) throws {
        let fm = FileManager.default
        let name = skillPath.lastPathComponent
        let storeVersion = storeDir.appendingPathComponent(name)

        guard fm.fileExists(atPath: storeVersion.path) else {
            throw SkillOpsError.message("本体库不存在同名 skill：\(name)")
        }
        guard let target else {
            throw SkillOpsError.message("无法确定 \(name) 所在的平台目录")
        }
        // 真实目录才需要链接化；软链本来就不用处理
        // 注意：URL.resourceValues 有实例级缓存，必须用 fileURLWithPath 新建的实例判断
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: skillPath.path)) != nil
        guard !isLink else { return }

        try fm.trashItem(at: skillPath, resultingItemURL: nil)
        let link = target.dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: link.path) {
            let rel = relativePath(from: target.dir, to: storeVersion)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: rel)
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openInEditor(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - 调用 / 触发

    /// 把「使用这个 skill」的提示词复制到剪贴板，粘到任何 agent 即可触发
    static func copyInvokePrompt(skill: Skill) {
        let prompt = "请使用 \(skill.name) 这个 skill 帮我完成任务。skill 位置：\(skill.canonicalPath.path)/SKILL.md。我的需求是："
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt, forType: .string)
    }

    static func copySkillMarkdown(skill: Skill) {
        guard let text = try? String(contentsOf: skill.skillMarkdownPath, encoding: .utf8) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 在 Terminal 里于用户主目录拉起指定 agent CLI 并预置 skill 指令
    static func launchAgentCLI(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        if let osa = NSAppleScript(source: script) {
            var err: NSDictionary?
            osa.executeAndReturnError(&err)
        }
    }

    // MARK: - 安装

    /// 安装来源：GitHub URL（整仓或子目录，支持 `repo@ref` 指定 tag/commit）或本地路径。
    /// 返回安装成功的 skill 目录名列表。
    /// 说明：现有安装流程没有 lock/版本记录文件（不改其他文件），
    /// 需要版本信息的调用方（如 UI 接线）请改用 `installWithRef`，它会把实际 checkout 的 ref 带出来。
    static func install(source: String, storeDir: URL, enableTargets: [AgentTarget]) throws -> [String] {
        try installWithRef(source: source, storeDir: storeDir, enableTargets: enableTargets).installed
    }

    /// 同 `install`，额外返回 git 源里 `@ref` 指定的版本（tag 或 commit SHA）；无 @ 时为 nil。
    /// 本地路径 source 不解析 @（路径里含 @ 很常见，只有 git 源才拆 ref）。
    static func installWithRef(
        source: String,
        storeDir: URL,
        enableTargets: [AgentTarget],
        selectedSkillID: String? = nil,
        selectedSkillName: String? = nil,
        lockFileURL: URL? = nil
    ) throws -> SkillInstallResult {
        let prepared = try prepareInstall(
            source: source,
            selectedSkillID: selectedSkillID,
            selectedSkillName: selectedSkillName
        )
        do {
            return try commitPreparedInstall(
                prepared,
                storeDir: storeDir,
                enableTargets: enableTargets,
                lockFileURL: lockFileURL
            )
        } catch {
            // 兼容旧的一步式调用：调用方没有确认页可以重试，因此失败时直接清理冻结内容。
            discardPreparedInstall(prepared)
            throw error
        }
    }

    /// 只下载、解析和检查，不修改本体库或任何 Agent 目录。
    static func prepareInstall(
        source: String,
        selectedSkillID: String? = nil,
        selectedSkillName: String? = nil
    ) throws -> PreparedSkillInstall {
        let fm = FileManager.default
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillOpsError.message("安装来源不能为空") }
        let tmp = fm.temporaryDirectory.appendingPathComponent("skillhub-\(UUID().uuidString)")
        var keepStagingDirectory = false
        defer {
            if !keepStagingDirectory { try? fm.removeItem(at: tmp) }
        }

        var rootToSearch: URL
        var resolvedRef: String? = nil
        var resolvedCommit: String? = nil
        var sourceType = "local"
        var sourceURL: String? = nil

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("git@") || trimmed.hasPrefix("file://") {
            sourceType = "git"
            let parsed = try parseGitInstallSource(trimmed)
            let repo = parsed.repository
            let subPath = parsed.subPath
            resolvedRef = parsed.ref
            sourceURL = repo
            // 指定了 ref 时不做浅克隆（否则 tag/SHA 可能不在浅历史里，checkout 会失败）
            if resolvedRef != nil {
                try runGit(["clone", repo, tmp.path])
                try runGit(["-C", tmp.path, "checkout", resolvedRef!], action: "checkout \(resolvedRef!)")
            } else {
                try runGit(["clone", "--depth", "1", repo, tmp.path])
            }
            resolvedCommit = runGitOutput(["-C", tmp.path, "rev-parse", "HEAD"])
            let candidate = subPath.map { tmp.appendingPathComponent($0) } ?? tmp
            let safeRoot = tmp.standardizedFileURL.path + "/"
            let safeCandidate = candidate.standardizedFileURL
            guard safeCandidate.path == tmp.standardizedFileURL.path || safeCandidate.path.hasPrefix(safeRoot) else {
                throw SkillOpsError.message("仓库子目录超出下载范围")
            }
            guard fm.fileExists(atPath: safeCandidate.path) else {
                throw SkillOpsError.message("仓库子目录不存在：\(subPath ?? "")")
            }
            rootToSearch = safeCandidate
        } else {
            let local = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            guard fm.fileExists(atPath: local.path) else {
                throw SkillOpsError.message("本地路径不存在：\(local.path)")
            }
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let frozen = tmp.appendingPathComponent(local.lastPathComponent, isDirectory: true)
            try fm.copyItem(at: local.resolvingSymlinksInPath(), to: frozen)
            rootToSearch = frozen
        }

        do {
            let discovered = findSkillDirs(in: rootToSearch)
            guard !discovered.isEmpty else {
                throw SkillOpsError.message("在来源里没有找到任何 SKILL.md")
            }

            let selected = try selectSkillDirs(
                discovered,
                selectedSkillID: selectedSkillID,
                selectedSkillName: selectedSkillName
            )
            let selectedPaths = Set(selected.map(\.standardizedFileURL.path))
            let skipped = discovered
                .filter { !selectedPaths.contains($0.standardizedFileURL.path) }
                .map { metadataName(for: $0) }
                .sorted()
            let items = try selected.map { dir in
                try makePreparedItem(from: dir, relativeTo: rootToSearch)
            }

            let prepared = PreparedSkillInstall(
                source: trimmed,
                sourceType: sourceType,
                sourceURL: sourceURL,
                requestedRef: resolvedRef,
                resolvedCommit: resolvedCommit,
                stagingRoot: tmp,
                items: items,
                skippedSkillNames: skipped
            )
            keepStagingDirectory = true
            return prepared
        } catch {
            throw error
        }
    }

    /// 解析 Git 仓库、`仓库@ref` 与 GitHub `tree/<ref>/<path>` 形式。
    /// tree URL 的 ref 使用单个路径段；含 `/` 的分支名与子目录无法无歧义拆分，暂不支持。
    static func parseGitInstallSource(_ source: String) throws -> GitInstallSource {
        var repository = source
        var subPath: String?
        var ref: String?

        if let range = source.range(of: "/tree/") {
            repository = String(source[..<range.lowerBound])
            let rest = String(source[range.upperBound...])
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let encodedRef = parts.first,
                  let decodedRef = String(encodedRef).removingPercentEncoding,
                  !decodedRef.isEmpty else {
                throw SkillOpsError.message("tree URL 缺少分支或 tag")
            }
            ref = decodedRef
            if parts.count == 2 {
                subPath = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }

        // 要求 @ 出现在最后一个 / 之后，避免误判 git@host:owner/repo 里的用户名 @。
        if let atIndex = repository.lastIndex(of: "@"),
           let slashIndex = repository.lastIndex(of: "/"),
           atIndex > slashIndex {
            guard ref == nil else {
                throw SkillOpsError.message("tree URL 不能同时使用 @ref")
            }
            ref = String(repository[repository.index(after: atIndex)...])
            repository = String(repository[..<atIndex])
        }

        if let ref {
            guard ref.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
                throw SkillOpsError.message("版本号不合法：\(ref.isEmpty ? "(空)" : ref)（支持 tag、commit SHA 或不含 / 的分支名）")
            }
        }
        guard !repository.isEmpty else { throw SkillOpsError.message("Git 仓库地址不能为空") }
        return GitInstallSource(repository: repository, subPath: subPath, ref: ref)
    }

    /// 将已确认的冻结内容原子写入本体库。任一步失败都会移除本次新建的链接与目录。
    static func commitPreparedInstall(
        _ prepared: PreparedSkillInstall,
        storeDir: URL,
        enableTargets: [AgentTarget],
        lockFileURL: URL? = nil
    ) throws -> SkillInstallResult {
        let fm = FileManager.default
        guard !prepared.items.isEmpty else {
            throw SkillOpsError.message("在来源里没有找到任何 SKILL.md")
        }

        let names = prepared.items.map(\.directoryName)
        guard Set(names).count == names.count else {
            throw SkillOpsError.message("来源里存在同名 skill，无法安全安装")
        }

        // 在写入前一次性检查所有冲突，避免安装到一半才失败。
        for item in prepared.items {
            let name = item.directoryName
            let dest = storeDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil {
                throw SkillOpsError.message("本体库已存在同名 skill：\(name)，请先卸载或改名")
            }
            for t in enableTargets {
                let link = t.dir.appendingPathComponent(name)
                if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                    throw SkillOpsError.message("\(t.displayName) 里已存在同名条目：\(name)")
                }
            }
        }

        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let transactionDir = storeDir.appendingPathComponent(".skillhub-install-\(prepared.id.uuidString)")
        var installedDestinations: [URL] = []
        var createdLinks: [URL] = []
        var createdTargetDirectories: [URL] = []
        do {
            try fm.createDirectory(at: transactionDir, withIntermediateDirectories: true)
            for item in prepared.items {
                let staged = transactionDir.appendingPathComponent(item.directoryName)
                try fm.copyItem(at: item.sourceDirectory, to: staged)
            }
            for item in prepared.items {
                let staged = transactionDir.appendingPathComponent(item.directoryName)
                let dest = storeDir.appendingPathComponent(item.directoryName)
                try fm.moveItem(at: staged, to: dest)
                installedDestinations.append(dest)
            }
            try? fm.removeItem(at: transactionDir)

            for item in prepared.items {
                let dest = storeDir.appendingPathComponent(item.directoryName)
                for target in enableTargets {
                    if !fm.fileExists(atPath: target.dir.path) {
                        try fm.createDirectory(at: target.dir, withIntermediateDirectories: true)
                        createdTargetDirectories.append(target.dir)
                    }
                    let link = target.dir.appendingPathComponent(item.directoryName)
                    let rel = relativePath(from: target.dir, to: dest)
                    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: rel)
                    createdLinks.append(link)
                    guard link.resolvingSymlinksInPath().standardizedFileURL.path == dest.standardizedFileURL.path else {
                        throw SkillOpsError.message("无法验证 \(target.displayName) 的启用链接")
                    }
                }
                guard fm.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path) else {
                    throw SkillOpsError.message("安装验证失败：\(item.name) 缺少 SKILL.md")
                }
            }

            let now = Date()
            let records = prepared.items.map { item in
                SkillInstallRecord(
                    skillName: item.name,
                    source: prepared.source,
                    sourceType: prepared.sourceType,
                    sourceURL: prepared.sourceURL,
                    skillPath: item.skillPath,
                    folderHash: item.folderHash,
                    installedAt: now,
                    resolvedRef: prepared.requestedRef,
                    resolvedCommit: prepared.resolvedCommit
                )
            }
            if let lockFileURL {
                var lock = SkillLockFile.load(from: lockFileURL)
                    ?? SkillLockFile(version: 1, skills: [:])
                for record in records { lock.recordInstall(record) }
                try lock.saveThrowing(to: lockFileURL)
            }
            let result = SkillInstallResult(
                installed: names,
                resolvedRef: prepared.requestedRef,
                resolvedCommit: prepared.resolvedCommit,
                records: records
            )
            // 只有成功后才销毁冻结内容；失败时保留，让确认页可以直接重试或取消。
            try? fm.removeItem(at: prepared.stagingRoot)
            return result
        } catch {
            for link in createdLinks.reversed() { try? fm.removeItem(at: link) }
            for dest in installedDestinations.reversed() { try? fm.removeItem(at: dest) }
            for directory in createdTargetDirectories.reversed() {
                if ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: directory)
                }
            }
            try? fm.removeItem(at: transactionDir)
            throw error
        }
    }

    static func discardPreparedInstall(_ prepared: PreparedSkillInstall) {
        try? FileManager.default.removeItem(at: prepared.stagingRoot)
    }

    private static func findSkillDirs(in root: URL) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return [root]
        }

        func walk(_ directory: URL, depth: Int, maxDepth: Int, into result: inout [URL]) {
            guard depth <= maxDepth else { return }
            if fm.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
                result.append(directory)
                return // 浅层 skill 遮蔽它内部的支持目录
            }
            let children = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            for child in children {
                let name = child.lastPathComponent
                guard name != ".git", name != "node_modules" else { continue }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory { walk(child, depth: depth + 1, maxDepth: maxDepth, into: &result) }
            }
        }

        var found: [URL] = []
        // 兼容 repo/<skill> 和 skills/<category>/<skill> 等常见布局。
        walk(root, depth: 0, maxDepth: 4, into: &found)
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func selectSkillDirs(
        _ dirs: [URL],
        selectedSkillID: String?,
        selectedSkillName: String?
    ) throws -> [URL] {
        let selectors = [selectedSkillID, selectedSkillName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !selectors.isEmpty else { return dirs }

        func matches(_ value: String, _ selector: String) -> Bool {
            value.compare(selector, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        // skillId/目录名优先，避免 display name 与另一个 skill 的 metadata.name 重合。
        let directoryMatches = dirs.filter { dir in selectors.contains { matches(dir.lastPathComponent, $0) } }
        if directoryMatches.count == 1 { return directoryMatches }
        if directoryMatches.count > 1 {
            throw SkillOpsError.message("来源里有多个目录匹配所选 skill，无法确定安装目标")
        }
        let metadataMatches = dirs.filter { dir in selectors.contains { matches(metadataName(for: dir), $0) } }
        if metadataMatches.count == 1 { return metadataMatches }
        if metadataMatches.count > 1 {
            throw SkillOpsError.message("来源里有多个 skill 使用同一个 name，无法安全安装")
        }
        let names = dirs.map { metadataName(for: $0) }.sorted().joined(separator: "、")
        throw SkillOpsError.message("仓库中未找到所选 skill。发现：\(names)")
    }

    private static func metadataName(for dir: URL) -> String {
        FrontmatterParser.parse(fileURL: dir.appendingPathComponent("SKILL.md")).name
            ?? dir.lastPathComponent
    }

    private static func makePreparedItem(from dir: URL, relativeTo root: URL) throws -> PreparedSkillInstall.Item {
        if let escaped = escapingSymlink(in: dir) {
            throw SkillOpsError.message("\(dir.lastPathComponent) 包含指向目录外的软链接：\(escaped)")
        }
        let fm = FileManager.default
        let md = dir.appendingPathComponent("SKILL.md")
        let parsed = FrontmatterParser.parse(fileURL: md)
        let name = parsed.name ?? dir.lastPathComponent
        let description = parsed.descriptionText ?? ""
        var warnings: [String] = []
        if !parsed.hasFrontmatter { warnings.append("SKILL.md 缺少有效 frontmatter") }
        if parsed.name == nil { warnings.append("缺少必填字段 name") }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("缺少必填字段 description") }
        if name != dir.lastPathComponent { warnings.append("name 与目录名不一致") }
        if name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil || name.count > 64 {
            warnings.append("name 不符合 Agent Skills 命名规范")
        }
        if description.count > 1024 { warnings.append("description 超过 1024 字符") }
        if let text = try? String(contentsOf: md, encoding: .utf8), text.components(separatedBy: .newlines).count > 500 {
            warnings.append("SKILL.md 超过建议的 500 行")
        }

        var files: [String] = []
        var size: Int64 = 0
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let relative = relativePathInside(root: dir, file: file)
                files.append(relative)
                size += Int64(values?.fileSize ?? 0)
            }
        }
        files.sort()
        return PreparedSkillInstall.Item(
            sourceDirectory: dir,
            directoryName: dir.lastPathComponent,
            name: name,
            descriptionText: description,
            skillPath: relativePathInside(root: root, file: dir),
            fileCount: files.count,
            sizeBytes: size,
            files: files,
            folderHash: folderHash(for: dir, files: files),
            securityReport: SecurityScanner.scan(directory: dir),
            validationWarnings: warnings
        )
    }

    private static func escapingSymlink(in root: URL) -> String? {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path + "/"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return nil }
        for case let url as URL in enumerator {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard isLink else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved != root.standardizedFileURL.path && !resolved.hasPrefix(rootPath) {
                return relativePathInside(root: root, file: url)
            }
        }
        return nil
    }

    private static func relativePathInside(root: URL, file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath != rootPath else { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : file.lastPathComponent
    }

    private static func folderHash(for root: URL, files: [String]) -> String {
        var hasher = SHA256()
        for path in files {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            if let data = try? Data(contentsOf: root.appendingPathComponent(path)) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runGit(_ args: [String], action: String = "clone") throws {
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillhub-git-error-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        guard let errorHandle = try? FileHandle(forWritingTo: errorFile) else {
            throw SkillOpsError.message("无法创建 git 日志")
        }
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorFile)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.standardError = errorHandle
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        guard waitForProcess(p, timeout: gitTimeout) else {
            throw SkillOpsError.message("git \(action) 超时（\(Int(gitTimeout)) 秒），请检查网络后重试")
        }
        if p.terminationStatus != 0 {
            try? errorHandle.synchronize()
            let data = (try? Data(contentsOf: errorFile)) ?? Data()
            let msg = String(data: data, encoding: .utf8) ?? "git 失败"
            throw SkillOpsError.message("git \(action) 失败：\(msg.prefix(300))")
        }
    }

    private static func runGitOutput(_ args: [String]) -> String? {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillhub-git-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputFile) else { return nil }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputFile)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.standardOutput = outputHandle
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        guard waitForProcess(p, timeout: gitTimeout), p.terminationStatus == 0 else { return nil }
        try? outputHandle.synchronize()
        guard let data = try? Data(contentsOf: outputFile) else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func waitForProcess(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return true }
        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    // MARK: - 工具

    /// 计算 from 目录到 to 的相对路径（与用户手工 ln -s 的习惯一致）
    static func relativePath(from: URL, to: URL) -> String {
        let fromParts = from.standardizedFileURL.pathComponents
        let toParts = to.standardizedFileURL.pathComponents
        var common = 0
        while common < min(fromParts.count, toParts.count), fromParts[common] == toParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        let downs = toParts[common...]
        let parts = ups + downs
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
