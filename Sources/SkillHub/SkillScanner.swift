import Foundation

/// 扫描所有 agent 目录，把软链接解析到本体后按本体去重，
/// 得到「每个 skill 在哪些 agent 里生效」的统一视图。
struct ScanOutcome {
    var skills: [Skill] = []
    var brokenLinks: [(agentID: String, url: URL, destination: String)] = []
}

/// 轻量列举结果：只做目录列举和 mtime 比对，不读 SKILL.md、不跑 git。
struct ScanPlan {
    /// canonicalPath -> (本体 URL, agentID -> 存在形式, hasSkillMarkdown)
    var skills: [String: (url: URL, presence: [String: PresenceKind], hasSkillMarkdown: Bool)] = [:]
    var brokenLinks: [(agentID: String, url: URL, destination: String)] = []
    /// canonicalPath -> 指纹
    var fingerprints: [String: String] = [:]

    /// 缓存是否完整覆盖本次列举（每个 skill 指纹都一致）
    func fullyCovered(by cache: ScanCache?) -> Bool {
        guard let cache else { return skills.isEmpty }
        return skills.keys.allSatisfy { path in
            cache.entries[path]?.fingerprint == fingerprints[path]
        }
    }
}

struct ScanResult {
    var outcome: ScanOutcome
    var cache: ScanCache
    /// 是否完全没有触发重新解析（全部命中缓存）
    var fullyFromCache: Bool
}

enum SkillScanner {

    /// 兼容旧调用：不带缓存的全量扫描
    static func scan(targets: [AgentTarget]) -> ScanOutcome {
        execute(plan: plan(targets: targets), cache: nil).outcome
    }

    /// 第一步：列举各平台目录，得到 skill 本体集合、presence、断链和指纹。
    /// 这一步只做文件系统元数据查询，耗时毫秒级。
    static func plan(targets: [AgentTarget]) -> ScanPlan {
        let fm = FileManager.default
        var plan = ScanPlan()

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
                    plan.brokenLinks.append((target.id, entry, dest))
                    continue
                }
                guard destExists && isDir.boolValue else { continue }
                // 目录无 SKILL.md 也纳入，标记为未规范
                let hasSKILL = fm.fileExists(atPath: resolved.appendingPathComponent("SKILL.md").path)

                let key = resolved.path
                if plan.skills[key] == nil {
                    plan.skills[key] = (resolved, [:], hasSKILL)
                    plan.fingerprints[key] = fingerprint(for: resolved, hasSkillMarkdown: hasSKILL)
                } else if hasSKILL {
                    // 如果任何 agent 有 SKILL.md，整个 skill 视为有
                    plan.skills[key]?.hasSkillMarkdown = true
                }
                plan.skills[key]?.presence[target.id] = isLink ? .symlink : .real
            }
        }
        return plan
    }

    /// 第二步：按指纹复用缓存，只有新增/变化的 skill 才解析 frontmatter、统计文件、跑 git。
    static func execute(plan: ScanPlan, cache: ScanCache?) -> ScanResult {
        var outcome = ScanOutcome()
        outcome.brokenLinks = plan.brokenLinks
        var newEntries: [String: CachedSkillEntry] = [:]
        var fullyFromCache = cache != nil

        for (path, info) in plan.skills {
            let fp = plan.fingerprints[path] ?? ""
            var skill: Skill
            if let entry = cache?.entries[path], entry.fingerprint == fp {
                skill = entry.makeSkill(canonicalPath: info.url)
                newEntries[path] = entry
            } else {
                fullyFromCache = false
                skill = makeSkill(canonical: info.url)
                newEntries[path] = CachedSkillEntry(skill: skill, fingerprint: fp)
            }
            skill.presence = info.presence
            skill.hasSkillMarkdown = info.hasSkillMarkdown
            outcome.skills.append(skill)
        }

        outcome.skills.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return ScanResult(
            outcome: outcome,
            cache: ScanCache(version: ScanCache.formatVersion, entries: newEntries),
            fullyFromCache: fullyFromCache
        )
    }

    /// skill 指纹：SKILL.md 修改时间 + skill 目录修改时间。
    /// 增删 skill 内文件、改 SKILL.md 都会让指纹变化；改子目录内容不会（可接受，见 ScanCache 注释）。
    static func fingerprint(for dir: URL, hasSkillMarkdown: Bool = true) -> String {
        let md = dir.appendingPathComponent("SKILL.md")
        let mdDate: Date? = hasSkillMarkdown ? (try? md.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
        let dirDate = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(mdDate?.timeIntervalSince1970 ?? 0)|\(dirDate?.timeIntervalSince1970 ?? 0)"
    }

    private static func makeSkill(canonical: URL) -> Skill {
        let fm = FileManager.default
        let md = canonical.appendingPathComponent("SKILL.md")
        let hasSKILL = fm.fileExists(atPath: md.path)
        let fmr = hasSKILL ? FrontmatterParser.parse(fileURL: md) : FrontmatterParser.Result()

        var skill = Skill(
            name: fmr.name ?? canonical.lastPathComponent,
            descriptionText: fmr.descriptionText ?? "",
            version: fmr.version,
            canonicalPath: canonical
        )
        skill.hasFrontmatter = fmr.hasFrontmatter
        skill.hasSkillMarkdown = hasSKILL
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
