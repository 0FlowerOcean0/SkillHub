import Foundation

/// 体检：断链、frontmatter 缺失、重名冲突、引用文件缺失、体积异常
enum Doctor {

    static func run(outcome: ScanOutcome, targets: [AgentTarget]) -> [DoctorIssue] {
        var issues: [DoctorIssue] = []
        let targetName: (String) -> String = { id in
            targets.first(where: { $0.id == id })?.displayName ?? id
        }

        // 1. 断链
        for broken in outcome.brokenLinks {
            issues.append(DoctorIssue(
                severity: .error,
                skillName: broken.url.lastPathComponent,
                title: "断链：\(targetName(broken.agentID)) / \(broken.url.lastPathComponent)",
                detail: "软链接指向不存在的目标：\(broken.destination)",
                fixAction: .deleteBrokenLink(broken.url)
            ))
        }

        // 2. 重名：不同本体、同一个 skill name
        var byName: [String: [Skill]] = [:]
        for s in outcome.skills { byName[s.name.lowercased(), default: []].append(s) }
        for (name, group) in byName where group.count > 1 {
            for skill in group {
                issues.append(DoctorIssue(
                    severity: .warning,
                    skillName: name,
                    title: "重名 skill：「\(name)」在多个位置存在",
                    detail: skill.canonicalPath.path,
                    hintActions: [.revealInFinder(skill.canonicalPath)]
                ))
            }
        }

        for skill in outcome.skills {
            // 3. frontmatter 校验
            if !skill.hasFrontmatter {
                issues.append(DoctorIssue(
                    severity: .error,
                    skillName: skill.name,
                    title: "\(skill.name)：SKILL.md 缺少 frontmatter",
                    detail: "缺少 --- 包裹的 name / description，多数 agent 无法加载。",
                    fixAction: .addFrontmatter(skill.skillMarkdownPath)
                ))
            } else if skill.descriptionText.isEmpty {
                issues.append(DoctorIssue(
                    severity: .warning,
                    skillName: skill.name,
                    title: "\(skill.name)：frontmatter 缺少 description",
                    detail: "没有 description，agent 无法判断何时触发这个 skill。",
                    fixAction: .addDescription(skill.skillMarkdownPath, skill.name)
                ))
            }

            // 4. 目录名与 frontmatter name 不一致
            let folder = skill.canonicalPath.lastPathComponent
            if skill.hasFrontmatter, folder != skill.name {
                issues.append(DoctorIssue(
                    severity: .info,
                    skillName: skill.name,
                    title: "\(skill.name)：目录名（\(folder)）与 name 不一致",
                    detail: "部分 agent 按目录名索引，建议保持一致。",
                    fixAction: .renameDirectory(skill.canonicalPath, skill.name)
                ))
            }

            // 5. SKILL.md 里引用的相对文件是否存在
            for missing in missingReferences(skill: skill).prefix(10) {
                issues.append(DoctorIssue(
                    severity: .warning,
                    skillName: skill.name,
                    title: "\(skill.name)：引用文件缺失 \(missing)",
                    detail: "SKILL.md 提到了 \(missing)，但目录里没有这个文件。",
                    fixAction: .removeReference(skill.skillMarkdownPath, missing)
                ))
            }

            // 6. 体积异常
            if skill.sizeBytes > 50 * 1024 * 1024 {
                issues.append(DoctorIssue(
                    severity: .info,
                    skillName: skill.name,
                    title: "\(skill.name)：体积偏大（\(skill.sizeDisplay)）",
                    detail: "可能包含了不必要的资产或测试数据。建议检查目录内容，清理后重新打包。",
                    hintActions: [.revealInFinder(skill.canonicalPath)]
                ))
            }

            // 7. 孤儿本体：只在本体库存在，没有任何 agent 启用
            let enabledAgents = skill.presence.keys.filter { $0 != AgentTarget.canonicalID }
            if enabledAgents.isEmpty,
               skill.presence[AgentTarget.canonicalID] != nil {
                let firstTarget = targets.first(where: { $0.exists && $0.id != AgentTarget.canonicalID })
                issues.append(DoctorIssue(
                    severity: .info,
                    skillName: skill.name,
                    title: "\(skill.name)：未被任何 agent 启用",
                    detail: firstTarget != nil
                        ? "本体在库里，但没有软链到任何 agent 的 skills 目录。"
                        : "本体在库里，但没有可用的 agent 目录。请先安装至少一个 agent，然后重新体检。",
                    fixAction: firstTarget.map { .enableInAgent(skill.canonicalPath.path, $0.id) } ?? .none,
                    hintActions: [.revealInFinder(skill.canonicalPath)]
                ))
            }

            // 8. 本体不在 canonical 本体库（.agents/skills）里
            //    （库内有软链指向同一本体的视为已收纳，不报）
            let canonicalStore = targets.first(where: { $0.id == AgentTarget.canonicalID })?.dir
            if let store = canonicalStore, !SkillManager.isRepresentedInStore(skill: skill, storeDir: store) {
                // 找到这个 skill 本体所在的 agent
                let realAgents = skill.presence.filter { $0.value == .real && $0.key != AgentTarget.canonicalID }
                if let hostAgent = realAgents.keys.first {
                    issues.append(DoctorIssue(
                        severity: .warning,
                        skillName: skill.name,
                        title: "\(skill.name)：本体不在本体库（在 \(targetName(hostAgent)) 里）",
                        detail: "本体实际位置：\(skill.canonicalPath.path)\n建议迁移到 \(store.path)，保持统一管理。",
                        fixAction: .migrateToStore(skill.canonicalPath, hostAgent)
                    ))
                }
            }
            // 9. 安全扫描：高危/中危转为 issue（低危只体现在报告分数里，避免噪音）
            let report = SecurityScanner.scan(skill: skill)
            let risky = report.findings.filter { $0.severity != .low }
            if !risky.isEmpty {
                let preview = risky.prefix(3)
                    .map { "\($0.file)：\($0.message)" }
                    .joined(separator: "\n")
                issues.append(DoctorIssue(
                    severity: risky.contains { $0.severity == .high } ? .error : .warning,
                    skillName: skill.name,
                    title: "\(skill.name)：安全扫描命中 \(risky.count) 条规则（评分 \(report.score)/100，\(report.grade.rawValue)）",
                    detail: preview,
                    fixAction: .none,
                    hintActions: [.revealInFinder(skill.canonicalPath)]
                ))
            }
        }

        return issues.sorted { $0.severity < $1.severity }
    }

    /// 从 SKILL.md 里提取 references/、scripts/、assets/ 相对引用并检查存在性
    static func missingReferences(skill: Skill) -> [String] {
        guard let text = try? String(contentsOf: skill.skillMarkdownPath, encoding: .utf8) else { return [] }
        // 前面不能紧跟字母数字或 "/"，避免把 URL（如 https://example.com/references/x.md）误判为相对引用
        let pattern = #"(?<![A-Za-z0-9/])(references|scripts|assets)/[A-Za-z0-9._\-/]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var missing: [String] = []
        let fm = FileManager.default
        for m in matches {
            var rel = ns.substring(with: m.range)
            while rel.hasSuffix(".") || rel.hasSuffix("/") { rel = String(rel.dropLast()) }
            guard !seen.contains(rel) else { continue }
            seen.insert(rel)
            guard rel.contains("."), !rel.hasSuffix(".md/") else { continue }
            let p = skill.canonicalPath.appendingPathComponent(rel).path
            if !fm.fileExists(atPath: p) {
                missing.append(rel)
            }
        }
        return missing
    }
}
