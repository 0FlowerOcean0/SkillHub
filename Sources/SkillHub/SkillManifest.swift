import Foundation

// MARK: - 技能清单（Manifest）导出 / 导入
//
// 用途：把当前 skills 清单导出为 JSON 文件，换机 / 团队共享时从清单一键装回。
// - 导出：`makeManifest` 纯函数，从扫描到的 skills + lock 文件生成清单
// - 导入：先 `planImport`（dry-run）生成计划供 UI 预览，再 `executeImport` 执行

/// 清单读写错误
enum SkillManifestError: LocalizedError {
    case unsupportedFormatVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let v):
            return "不支持的清单格式版本：\(v)（当前支持 \(SkillManifest.currentFormatVersion)）"
        }
    }
}

struct SkillManifest: Codable, Equatable {

    /// 当前清单格式版本
    static let currentFormatVersion = 1

    var formatVersion: Int = SkillManifest.currentFormatVersion
    var exportedAt: Date = Date()
    var appVersion: String? = nil
    var entries: [Entry]

    /// 单个 skill 的清单条目
    struct Entry: Codable, Equatable {
        var name: String
        /// 安装来源（git URL 或本地路径）；本地手动安装、无来源可追溯的 skill 为 nil
        var source: String?
        /// 当前启用到的平台 ID 列表（不含本体库 canonical）
        var enabledTargetIDs: [String]
        var tags: [String]? = nil
    }

    init(entries: [Entry], appVersion: String? = nil, exportedAt: Date = Date()) {
        self.entries = entries
        self.appVersion = appVersion
        self.exportedAt = exportedAt
    }

    // MARK: - 导出

    /// 生成清单（纯函数）。
    /// - parameters:
    ///   - skills: 当前扫描到的全部 skill
    ///   - lockFile: ~/.agents/.skill-lock.json 的内容（可为 nil）
    ///   - canonicalID: 本体库平台 ID，enabledTargetIDs 里会剔除它
    static func makeManifest(
        skills: [Skill],
        lockFile: SkillLockFile?,
        canonicalID: String = AgentTarget.canonicalID,
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        exportedAt: Date = Date()
    ) -> SkillManifest {
        let entries = skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                Entry(
                    name: skill.name,
                    source: resolveSource(for: skill, lockFile: lockFile),
                    enabledTargetIDs: skill.presence
                        .filter { $0.key != canonicalID && $0.value != .broken }
                        .map(\.key)
                        .sorted(),
                    tags: skill.tags.isEmpty ? nil : skill.tags
                )
            }
        return SkillManifest(entries: entries, appVersion: appVersion, exportedAt: exportedAt)
    }

    /// 解析安装来源：优先 lock 文件的 sourceUrl / source，其次 git remote；都没有则为 nil
    private static func resolveSource(for skill: Skill, lockFile: SkillLockFile?) -> String? {
        if let lock = lockFile?.skills[skill.name] {
            if let url = lock.sourceUrl, !url.isEmpty { return url }
            if let s = lock.source, !s.isEmpty, s != "unknown" { return s }
        }
        if let remote = skill.gitRemote, !remote.isEmpty { return remote }
        return nil
    }

    // MARK: - 导入规划（dry-run）

    /// 已存在、只需补启用平台的动作
    struct EnableAction {
        let entry: Entry
        let skill: Skill
        /// 清单要求启用、但当前未启用的平台 ID
        let missingTargetIDs: [String]
    }

    /// 导入计划：UI 可据此展示「将安装 X 个、启用 Y 个、跳过 Z 个」
    struct ImportPlan {
        /// 本地不存在，需要新安装
        var toInstall: [Entry] = []
        /// 本地已存在，但平台启用不一致，需要补启用
        var toEnable: [EnableAction] = []
        /// 本地已存在且平台启用完全一致，跳过
        var alreadyOK: [Entry] = []

        var installCount: Int { toInstall.count }
        var enableCount: Int { toEnable.count }
        var skipCount: Int { alreadyOK.count }
        var isEmpty: Bool { toInstall.isEmpty && toEnable.isEmpty }
    }

    /// 根据清单和本地已有 skills 生成导入计划（纯函数）
    static func planImport(manifest: SkillManifest, existingSkills: [Skill]) -> ImportPlan {
        var plan = ImportPlan()
        let byName = Dictionary(existingSkills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in manifest.entries {
            guard let skill = byName[entry.name] else {
                plan.toInstall.append(entry)
                continue
            }
            // 与导出口径一致：剔除本体库和断链
            let enabledNow = Set(
                skill.presence
                    .filter { $0.key != AgentTarget.canonicalID && $0.value != .broken }
                    .map(\.key)
            )
            let missing = entry.enabledTargetIDs.filter { !enabledNow.contains($0) }
            if missing.isEmpty {
                plan.alreadyOK.append(entry)
            } else {
                plan.toEnable.append(EnableAction(entry: entry, skill: skill, missingTargetIDs: missing))
            }
        }
        return plan
    }

    // MARK: - 执行导入

    /// 导入结果统计（skipped / failed 均带原因说明）
    struct ImportResult {
        var installed: [String] = []
        var enabled: [(skill: String, targetID: String)] = []
        var skipped: [(name: String, reason: String)] = []
        var failed: [(name: String, error: String)] = []

        var summary: String {
            "安装 \(installed.count) 个，启用 \(enabled.count) 项，跳过 \(skipped.count) 个，失败 \(failed.count) 个"
        }
    }

    /// 执行导入计划：
    /// - 需安装的 entry 有 source 才调用 SkillOps.install；无 source 记入 skipped
    /// - 已存在的用 SkillOps.enable 补启用；目标平台在本机不存在则记入 skipped
    /// - 单个失败不中断整体流程，错误明细记入 failed
    /// - parameters:
    ///   - plan: planImport 生成的计划
    ///   - storeDir: 本体库目录（新安装的 skill 放这里）
    ///   - targets: 本机全部平台（用于把 enabledTargetIDs 解析成 AgentTarget）
    static func executeImport(plan: ImportPlan, storeDir: URL, targets: [AgentTarget]) -> ImportResult {
        var result = ImportResult()

        // 1. 新安装
        for entry in plan.toInstall {
            guard let source = entry.source, !source.isEmpty else {
                result.skipped.append((entry.name, "没有安装来源（本地手动安装的 skill），无法自动安装"))
                continue
            }
            let enableTargets = targets.filter {
                entry.enabledTargetIDs.contains($0.id) && $0.id != AgentTarget.canonicalID
            }
            do {
                _ = try SkillOps.install(source: source, storeDir: storeDir, enableTargets: enableTargets)
                result.installed.append(entry.name)
            } catch {
                result.failed.append((entry.name, error.localizedDescription))
            }
        }

        // 2. 补启用
        for action in plan.toEnable {
            for targetID in action.missingTargetIDs {
                guard let target = targets.first(where: { $0.id == targetID }) else {
                    result.skipped.append((action.entry.name, "本机不存在平台「\(targetID)」，跳过启用"))
                    continue
                }
                do {
                    try SkillOps.enable(skill: action.skill, in: target)
                    result.enabled.append((action.entry.name, targetID))
                } catch {
                    result.failed.append((action.entry.name, "\(targetID)：\(error.localizedDescription)"))
                }
            }
        }

        // 3. 完全一致的记为跳过
        for entry in plan.alreadyOK {
            result.skipped.append((entry.name, "已存在且平台启用一致"))
        }

        return result
    }

    // MARK: - 文件读写

    /// 编码器：prettyPrinted + sortedKeys，日期用 ISO8601，便于人工查看和 git diff
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 写出清单 JSON 文件
    func write(to url: URL) throws {
        let data = try SkillManifest.makeEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// 从 JSON 文件读取清单；formatVersion 不识别时抛 SkillManifestError.unsupportedFormatVersion
    static func load(from url: URL) throws -> SkillManifest {
        let data = try Data(contentsOf: url)
        let manifest = try makeDecoder().decode(SkillManifest.self, from: data)
        guard manifest.formatVersion >= 1 && manifest.formatVersion <= currentFormatVersion else {
            throw SkillManifestError.unsupportedFormatVersion(manifest.formatVersion)
        }
        return manifest
    }
}
