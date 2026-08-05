import Foundation

/// 扫描所有 agent 目录，把软链接解析到本体后按本体去重，
/// 得到「每个 skill 在哪些 agent 里生效」的统一视图。
struct ScanOutcome {
    var skills: [Skill] = []
    var brokenLinks: [(agentID: String, url: URL, destination: String)] = []
}

enum SkillScanner {

    static func scan(targets: [AgentTarget]) -> ScanOutcome {
        let fm = FileManager.default
        var outcome = ScanOutcome()
        // canonicalPath -> Skill
        var byCanonical: [String: Skill] = [:]

        for target in targets where target.exists {
            let entries = (try? fm.contentsOfDirectory(
                at: target.dir,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey])
                let isLink = values?.isSymbolicLink ?? false
                let resolved = entry.resolvingSymlinksInPath()

                var isDir: ObjCBool = false
                let destExists = fm.fileExists(atPath: resolved.path, isDirectory: &isDir)

                if isLink && !destExists {
                    let dest = (try? fm.destinationOfSymbolicLink(atPath: entry.path)) ?? "?"
                    outcome.brokenLinks.append((target.id, entry, dest))
                    continue
                }
                guard destExists && isDir.boolValue else { continue }
                // 只认包含 SKILL.md 的目录为 skill
                guard fm.fileExists(atPath: resolved.appendingPathComponent("SKILL.md").path) else { continue }

                let key = resolved.path
                if byCanonical[key] == nil {
                    byCanonical[key] = makeSkill(canonical: resolved)
                }
                byCanonical[key]?.presence[target.id] = isLink ? .symlink : .real
            }
        }

        outcome.skills = byCanonical.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return outcome
    }

    private static func makeSkill(canonical: URL) -> Skill {
        let fm = FileManager.default
        let md = canonical.appendingPathComponent("SKILL.md")
        let fmr = FrontmatterParser.parse(fileURL: md)

        var skill = Skill(
            name: fmr.name ?? canonical.lastPathComponent,
            descriptionText: fmr.descriptionText ?? "",
            version: fmr.version,
            canonicalPath: canonical
        )
        skill.hasFrontmatter = fmr.hasFrontmatter
        skill.tags = fmr.tags
        skill.summary = fmr.summary ?? ""

        // 作者：优先 frontmatter，否则从目录名提取前缀（如 ljg-xxx -> ljg）
        if let author = fmr.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            skill.author = author
        } else {
            skill.author = extractAuthorFromDirectoryName(canonical.lastPathComponent)
        }

        // 统计文件数与体积、支持目录
        var count = 0
        var size: Int64 = 0
        if let en = fm.enumerator(at: canonical, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    count += 1
                    size += Int64(v?.fileSize ?? 0)
                }
            }
        }
        skill.fileCount = count
        skill.sizeBytes = size
        skill.supportDirs = ["references", "scripts", "assets", "evals", "agents"].filter {
            var d: ObjCBool = false
            return fm.fileExists(atPath: canonical.appendingPathComponent($0).path, isDirectory: &d) && d.boolValue
        }

        // 检测 git 来源
        if let (remote, branch, commit) = gitInfo(for: canonical) {
            skill.gitRemote = remote
            skill.gitBranch = branch
            skill.gitLastCommit = commit
        }

        return skill
    }

    /// 从目录名提取作者前缀（如 ljg-xxx -> ljg, myauthor-skillname -> myauthor）
    private static func extractAuthorFromDirectoryName(_ dirName: String) -> String {
        // 如果包含连字符，取第一段作为作者
        if let dashIndex = dirName.firstIndex(of: "-") {
            let prefix = String(dirName[..<dashIndex]).trimmingCharacters(in: .whitespaces)
            // 确保前缀不是太短（至少2个字符）且不是纯数字
            if prefix.count >= 2 && !prefix.allSatisfy(\.isNumber) {
                return prefix
            }
        }
        return ""
    }

    private static func gitInfo(for dir: URL) -> (remote: String, branch: String, commit: String)? {
        let fm = FileManager.default
        // 向上查找 .git 目录
        var check = dir
        while check.path != "/" {
            if fm.fileExists(atPath: check.appendingPathComponent(".git").path) {
                break
            }
            check = check.deletingLastPathComponent()
        }
        guard fm.fileExists(atPath: check.appendingPathComponent(".git").path) else { return nil }

        func run(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = check
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let remote = run(["remote", "get-url", "origin"]),
              !remote.isEmpty,
              let branch = run(["branch", "--show-current"]),
              !branch.isEmpty,
              let commit = run(["rev-parse", "--short", "HEAD"]),
              !commit.isEmpty else { return nil }

        return (remote, branch, commit)
    }
}
