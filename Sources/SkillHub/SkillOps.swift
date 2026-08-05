import Foundation
import AppKit

enum SkillOpsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// 管理（启用/禁用/删除）、安装（GitHub / 本地）、调用（复制提示词 / 打开）
enum SkillOps {

    // MARK: - 启用 / 禁用

    /// 在指定 agent 目录创建指向本体的相对软链接
    static func enable(skill: Skill, in target: AgentTarget) throws {
        let fm = FileManager.default
        if !target.exists {
            try fm.createDirectory(at: target.dir, withIntermediateDirectories: true)
        }
        let linkPath = target.dir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
        if fm.fileExists(atPath: linkPath.path) || (try? fm.destinationOfSymbolicLink(atPath: linkPath.path)) != nil {
            throw SkillOpsError.message("\(target.displayName) 里已存在同名条目：\(linkPath.lastPathComponent)")
        }
        let relative = relativePath(from: target.dir, to: skill.canonicalPath)
        try fm.createSymbolicLink(atPath: linkPath.path, withDestinationPath: relative)
    }

    /// 只移除软链接；本体目录绝不通过 disable 删除
    static func disable(skill: Skill, in target: AgentTarget) throws {
        let fm = FileManager.default
        let entry = target.dir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
        guard let _ = try? fm.destinationOfSymbolicLink(atPath: entry.path) else {
            throw SkillOpsError.message("\(entry.lastPathComponent) 在 \(target.displayName) 里是真实目录（本体），不会自动删除。请先迁移本体。")
        }
        try fm.removeItem(at: entry)
    }

    /// 删除本体：先移除各 agent 目录里的软链，再把本体移入废纸篓
    static func trash(skill: Skill, targets: [AgentTarget]) throws {
        let fm = FileManager.default
        for t in targets {
            let entry = t.dir.appendingPathComponent(skill.canonicalPath.lastPathComponent)
            if (try? fm.destinationOfSymbolicLink(atPath: entry.path)) != nil,
               entry.resolvingSymlinksInPath().path == skill.canonicalPath.path {
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

    /// 安装来源：GitHub URL（整仓或子目录）或本地路径。
    /// 返回安装成功的 skill 目录名列表。
    static func install(source: String, storeDir: URL, enableTargets: [AgentTarget]) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmp = fm.temporaryDirectory.appendingPathComponent("skillhub-\(UUID().uuidString)")

        var rootToSearch: URL

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("git@") {
            // 解析 github tree 子目录形式
            var repo = trimmed
            var subPath: String? = nil
            if let range = trimmed.range(of: "/tree/") {
                repo = String(trimmed[..<range.lowerBound])
                let rest = String(trimmed[range.upperBound...]) // <branch>/<path...>
                let parts = rest.split(separator: "/", maxSplits: 1)
                if parts.count == 2 { subPath = String(parts[1]) }
            }
            try runGit(["clone", "--depth", "1", repo, tmp.path])
            rootToSearch = subPath.map { tmp.appendingPathComponent($0) } ?? tmp
        } else {
            let local = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            guard fm.fileExists(atPath: local.path) else {
                throw SkillOpsError.message("本地路径不存在：\(local.path)")
            }
            rootToSearch = local
        }

        defer { if rootToSearch.path.hasPrefix(fm.temporaryDirectory.path) { try? fm.removeItem(at: tmp) } }

        // 找出所有 SKILL.md 所在目录（根目录本身，或一级/skills 子目录）
        let skillDirs = findSkillDirs(in: rootToSearch)
        guard !skillDirs.isEmpty else {
            throw SkillOpsError.message("在来源里没有找到任何 SKILL.md")
        }

        var installed: [String] = []
        for dir in skillDirs {
            let name = dir.lastPathComponent
            let dest = storeDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                throw SkillOpsError.message("本体库已存在同名 skill：\(name)，请先卸载或改名")
            }
            try fm.copyItem(at: dir, to: dest)
            installed.append(name)

            // 建软链到勾选的 agent
            for t in enableTargets {
                if !t.exists { try? fm.createDirectory(at: t.dir, withIntermediateDirectories: true) }
                let link = t.dir.appendingPathComponent(name)
                if !fm.fileExists(atPath: link.path), (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
                    let rel = relativePath(from: t.dir, to: dest)
                    try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: rel)
                }
            }
        }
        return installed
    }

    private static func findSkillDirs(in root: URL) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return [root]
        }
        var found: [URL] = []
        for base in [root, root.appendingPathComponent("skills")] {
            let entries = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for e in entries {
                var d: ObjCBool = false
                if fm.fileExists(atPath: e.path, isDirectory: &d), d.boolValue,
                   fm.fileExists(atPath: e.appendingPathComponent("SKILL.md").path) {
                    found.append(e)
                }
            }
            if !found.isEmpty { break }
        }
        return found
    }

    private static func runGit(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "git 失败"
            throw SkillOpsError.message("git clone 失败：\(msg.prefix(300))")
        }
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
