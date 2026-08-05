import Foundation

// MARK: - 场景（Preset）数据模型

/// 「场景」= 一组 skill 的命名集合 + 目标平台集合，
/// 用于按工作场景（如"前端开发"）一键切换启用状态。
struct SkillPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var skillNames: [String]
    /// 生效的 agent 平台 id 列表；为空表示对所有非本体库平台生效
    var targetIDs: [String]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, skillNames: [String] = [], targetIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.skillNames = skillNames
        self.targetIDs = targetIDs
        self.createdAt = createdAt
    }
}

// MARK: - PresetStore：纯逻辑层（UserDefaults 持久化 + 集合操作）

/// 持久化风格参考 SkillManager.favorites：JSON 编码后存 UserDefaults。
/// 集合操作都是静态纯函数，便于单元测试；实例方法只负责读写。
struct PresetStore {
    static let defaultsKey = "skillPresets"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: 持久化

    func load() -> [SkillPreset] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let presets = try? JSONDecoder().decode([SkillPreset].self, from: data) else {
            return []
        }
        // 按创建时间排序，保证侧边栏顺序稳定
        return presets.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ presets: [SkillPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: 纯函数集合操作

    @discardableResult
    static func add(_ presets: inout [SkillPreset], name: String) -> SkillPreset {
        let preset = SkillPreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        presets.append(preset)
        return preset
    }

    static func remove(_ presets: inout [SkillPreset], id: UUID) {
        presets.removeAll { $0.id == id }
    }

    static func rename(_ presets: inout [SkillPreset], id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].name = trimmed
    }

    static func addSkill(_ presets: inout [SkillPreset], id: UUID, skillName: String) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        guard !presets[idx].skillNames.contains(skillName) else { return }
        presets[idx].skillNames.append(skillName)
    }

    static func removeSkill(_ presets: inout [SkillPreset], id: UUID, skillName: String) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].skillNames.removeAll { $0 == skillName }
    }

    /// 改写场景的目标平台集合（空数组 = 对所有非本体库平台生效）
    static func setTargets(_ presets: inout [SkillPreset], id: UUID, targetIDs: [String]) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].targetIDs = targetIDs
    }

    /// 解析生效目标平台：targetIDs 为空时默认对所有非本体库平台生效
    static func effectiveTargets(for preset: SkillPreset, allTargets: [AgentTarget]) -> [AgentTarget] {
        let nonStore = allTargets.filter { $0.id != AgentTarget.canonicalID }
        guard !preset.targetIDs.isEmpty else { return nonStore }
        let ids = Set(preset.targetIDs)
        return nonStore.filter { ids.contains($0.id) }
    }
}

// MARK: - PresetOps：激活 / 停用编排（纯逻辑，文件操作经 SkillOps）

enum PresetOps {
    struct ActivationResult {
        var success = 0            // 本次实际改变状态的次数
        var skipped = 0            // 已是目标状态，跳过
        var failed: [String] = []  // 文件操作失败（如目标已存在同名条目）
        var missing: [String] = [] // skill 已不存在（被删除）
    }

    /// 激活：对组内每个 skill 在每个生效平台上执行 enable，已启用的跳过。
    /// 注意：调用方负责在循环结束后统一 refresh，不要在这里刷新。
    static func activate(preset: SkillPreset, skills: [Skill], targets: [AgentTarget]) -> ActivationResult {
        var result = ActivationResult()
        for name in preset.skillNames {
            guard let skill = skills.first(where: { $0.name == name }) else {
                result.missing.append(name)
                continue
            }
            for target in targets {
                if skill.presence[target.id] != nil {
                    result.skipped += 1
                    continue
                }
                do {
                    try SkillOps.enable(skill: skill, in: target)
                    result.success += 1
                } catch {
                    result.failed.append("\(name) → \(target.displayName)：\(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// 停用：同理执行 disable，未启用的跳过；本体目录绝不删除（由 SkillOps.disable 保证）
    static func deactivate(preset: SkillPreset, skills: [Skill], targets: [AgentTarget]) -> ActivationResult {
        var result = ActivationResult()
        for name in preset.skillNames {
            guard let skill = skills.first(where: { $0.name == name }) else {
                result.missing.append(name)
                continue
            }
            for target in targets {
                if skill.presence[target.id] == nil {
                    result.skipped += 1
                    continue
                }
                do {
                    try SkillOps.disable(skill: skill, in: target)
                    result.success += 1
                } catch {
                    result.failed.append("\(name) → \(target.displayName)：\(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// 汇总成一行中文提示，供 AppState notice 使用
    static func summary(action: String, preset: SkillPreset, result: ActivationResult) -> String {
        var parts = ["已\(action)「\(preset.name)」：成功 \(result.success) 项"]
        if result.skipped > 0 { parts.append("跳过 \(result.skipped) 项（已是目标状态）") }
        if !result.failed.isEmpty { parts.append("失败 \(result.failed.count) 项") }
        if !result.missing.isEmpty { parts.append("\(result.missing.count) 个 skill 已不存在") }
        return parts.joined(separator: "，")
    }
}
