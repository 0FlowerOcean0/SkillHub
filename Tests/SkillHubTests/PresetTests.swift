import XCTest
@testable import SkillHub

final class PresetTests: XCTestCase {

    // 使用独立 suite 的 UserDefaults，避免污染真实偏好
    private func makeStore() -> (PresetStore, UserDefaults) {
        let name = "skillhub-preset-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (PresetStore(defaults: defaults), defaults)
    }

    // MARK: - PresetStore 纯函数：增删改

    func testAddTrimsNameAndAppends() {
        var presets: [SkillPreset] = []
        let p = PresetStore.add(&presets, name: "  前端开发  ")
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(p.name, "前端开发")
        XCTAssertEqual(presets.first?.id, p.id)
        XCTAssertTrue(p.skillNames.isEmpty)
        XCTAssertTrue(p.targetIDs.isEmpty)
    }

    func testRemoveByID() {
        var presets: [SkillPreset] = []
        let a = PresetStore.add(&presets, name: "a")
        _ = PresetStore.add(&presets, name: "b")
        PresetStore.remove(&presets, id: a.id)
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets.first?.name, "b")
        // 删除不存在的 id 不应崩溃
        PresetStore.remove(&presets, id: UUID())
        XCTAssertEqual(presets.count, 1)
    }

    func testRenameTrimsAndIgnoresEmpty() {
        var presets: [SkillPreset] = []
        let p = PresetStore.add(&presets, name: "旧名字")
        PresetStore.rename(&presets, id: p.id, name: " 新名字 ")
        XCTAssertEqual(presets.first?.name, "新名字")
        // 空名字不应生效
        PresetStore.rename(&presets, id: p.id, name: "   ")
        XCTAssertEqual(presets.first?.name, "新名字")
        // 不存在的 id 不应崩溃
        PresetStore.rename(&presets, id: UUID(), name: "x")
        XCTAssertEqual(presets.first?.name, "新名字")
    }

    func testAddSkillDeduplicates() {
        var presets: [SkillPreset] = []
        let p = PresetStore.add(&presets, name: "场景")
        PresetStore.addSkill(&presets, id: p.id, skillName: "foo")
        PresetStore.addSkill(&presets, id: p.id, skillName: "foo")
        PresetStore.addSkill(&presets, id: p.id, skillName: "bar")
        XCTAssertEqual(presets.first?.skillNames, ["foo", "bar"])
        // 不存在的 id 不应崩溃
        PresetStore.addSkill(&presets, id: UUID(), skillName: "x")
        XCTAssertEqual(presets.first?.skillNames.count, 2)
    }

    func testRemoveSkill() {
        var presets: [SkillPreset] = []
        let p = PresetStore.add(&presets, name: "场景")
        PresetStore.addSkill(&presets, id: p.id, skillName: "foo")
        PresetStore.removeSkill(&presets, id: p.id, skillName: "foo")
        XCTAssertEqual(presets.first?.skillNames, [])
        // 移除不存在的 skill / 不存在的 id 不应崩溃
        PresetStore.removeSkill(&presets, id: p.id, skillName: "foo")
        PresetStore.removeSkill(&presets, id: UUID(), skillName: "x")
        XCTAssertEqual(presets.first?.skillNames, [])
    }

    // MARK: - 持久化往返

    func testPersistenceRoundTrip() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.load(), [], "全新 suite 应为空")

        var presets: [SkillPreset] = []
        let p1 = PresetStore.add(&presets, name: "前端开发")
        PresetStore.addSkill(&presets, id: p1.id, skillName: "react-helper")
        var list = presets
        PresetStore.addSkill(&list, id: p1.id, skillName: "css-lint")
        list[0].targetIDs = ["claude", "cursor"]
        _ = PresetStore.add(&list, name: "写作")

        store.save(list)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        // 按 createdAt 排序，先创建的在前面
        XCTAssertEqual(loaded[0].name, "前端开发")
        XCTAssertEqual(loaded[0].skillNames, ["react-helper", "css-lint"])
        XCTAssertEqual(loaded[0].targetIDs, ["claude", "cursor"])
        XCTAssertEqual(loaded[1].name, "写作")

        // 损坏数据应安全返回空
        let (store2, defaults2) = makeStore()
        defaults2.set(Data("not json".utf8), forKey: PresetStore.defaultsKey)
        XCTAssertEqual(store2.load(), [])
    }

    // MARK: - effectiveTargets 平台过滤

    func testEffectiveTargetsEmptyMeansAllNonStore() {
        let all = AgentTarget.builtin(home: URL(fileURLWithPath: "/tmp/u"))
        let preset = SkillPreset(name: "场景", targetIDs: [])
        let effective = PresetStore.effectiveTargets(for: preset, allTargets: all)
        XCTAssertEqual(effective.count, all.count - 1, "应排除本体库")
        XCTAssertFalse(effective.contains { $0.id == AgentTarget.canonicalID })
    }

    func testEffectiveTargetsFiltersByIDsAndExcludesStore() {
        let all = AgentTarget.builtin(home: URL(fileURLWithPath: "/tmp/u"))
        // 即使把本体库 id 写进 targetIDs，也要被排除
        let preset = SkillPreset(name: "场景", targetIDs: ["claude", "agents", "nonexistent"])
        let effective = PresetStore.effectiveTargets(for: preset, allTargets: all)
        XCTAssertEqual(effective.map(\.id), ["claude"])
    }

    // MARK: - PresetOps 激活 / 停用（TempSandbox 文件沙盒）

    func testActivateEnablesMissingAndSkipsEnabled() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/foo", frontmatter: "---\nname: foo\n---\n")
        let store = box.makeTarget("agents", "store/skills")
        let agentA = box.makeTarget("agentA", "a/skills")
        let agentB = box.makeTarget("agentB", "b/skills")

        var skill = Skill(name: "foo", descriptionText: "", version: nil, canonicalPath: canonical)
        skill.presence = ["agents": .real, "agentB": .symlink]   // agentB 已启用

        let preset = SkillPreset(name: "场景", skillNames: ["foo"])
        let targets = PresetStore.effectiveTargets(for: preset, allTargets: [store, agentA, agentB])

        let result = PresetOps.activate(preset: preset, skills: [skill], targets: targets)
        XCTAssertEqual(result.success, 1, "只应在 agentA 新建软链")
        XCTAssertEqual(result.skipped, 1, "agentB 已启用应跳过")
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)

        let link = agentA.dir.appendingPathComponent("foo")
        XCTAssertEqual(link.resolvingSymlinksInPath().standardizedFileURL.path,
                       canonical.standardizedFileURL.path)
    }

    func testActivateCountsMissingSkills() throws {
        let box = try TempSandbox()
        let agentA = box.makeTarget("agentA", "a/skills")
        let preset = SkillPreset(name: "场景", skillNames: ["ghost"])

        let result = PresetOps.activate(preset: preset, skills: [], targets: [agentA])
        XCTAssertEqual(result.missing, ["ghost"], "已删除的 skill 应计入缺失")
        XCTAssertEqual(result.success, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    func testDeactivateRemovesLinksAndSkipsAbsent() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/foo", frontmatter: "---\nname: foo\n---\n")
        let agentA = box.makeTarget("agentA", "a/skills")
        let agentB = box.makeTarget("agentB", "b/skills")

        var skill = Skill(name: "foo", descriptionText: "", version: nil, canonicalPath: canonical)
        try SkillOps.enable(skill: skill, in: agentA)
        skill.presence = ["agentA": .symlink]   // agentB 未启用

        let preset = SkillPreset(name: "场景", skillNames: ["foo"])
        let result = PresetOps.deactivate(preset: preset, skills: [skill], targets: [agentA, agentB])
        XCTAssertEqual(result.success, 1)
        XCTAssertEqual(result.skipped, 1, "agentB 未启用应跳过")
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(box.fm.fileExists(atPath: agentA.dir.appendingPathComponent("foo").path))
        // 本体仍在
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.appendingPathComponent("SKILL.md").path))
    }

    func testDeactivateCountsFailureForRealDirectory() throws {
        let box = try TempSandbox()
        // 在 agent 目录里放一个真实目录（本体），disable 必须拒绝并计入失败
        let canonical = try box.makeSkillDir("a/skills/foo", frontmatter: "---\nname: foo\n---\n")
        let agentA = box.makeTarget("agentA", "a/skills")
        var skill = Skill(name: "foo", descriptionText: "", version: nil, canonicalPath: canonical)
        skill.presence = ["agentA": .real]

        let preset = SkillPreset(name: "场景", skillNames: ["foo"])
        let result = PresetOps.deactivate(preset: preset, skills: [skill], targets: [agentA])
        XCTAssertEqual(result.failed.count, 1, "真实目录不能被 disable，应计入失败")
        XCTAssertEqual(result.success, 0)
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.path), "本体必须保留")
    }

    func testActivateRespectsTargetIDsSubset() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/foo", frontmatter: "---\nname: foo\n---\n")
        let agentA = box.makeTarget("agentA", "a/skills")
        let agentB = box.makeTarget("agentB", "b/skills")

        let skill = Skill(name: "foo", descriptionText: "", version: nil, canonicalPath: canonical)
        let preset = SkillPreset(name: "场景", skillNames: ["foo"], targetIDs: ["agentA"])
        let targets = PresetStore.effectiveTargets(for: preset, allTargets: [agentA, agentB])
        XCTAssertEqual(targets.map(\.id), ["agentA"], "targetIDs 限定时只对指定平台生效")

        let result = PresetOps.activate(preset: preset, skills: [skill], targets: targets)
        XCTAssertEqual(result.success, 1)
        XCTAssertTrue(box.fm.fileExists(atPath: agentA.dir.appendingPathComponent("foo").path))
        XCTAssertFalse(box.fm.fileExists(atPath: agentB.dir.appendingPathComponent("foo").path),
                       "未在 targetIDs 里的平台不应被启用")
    }

    // MARK: - 汇总文案

    func testSummaryIncludesAllCounts() {
        var result = PresetOps.ActivationResult()
        result.success = 2
        result.skipped = 1
        result.failed = ["x"]
        result.missing = ["ghost"]
        let text = PresetOps.summary(action: "激活", preset: SkillPreset(name: "场景"), result: result)
        XCTAssertTrue(text.contains("已激活「场景」"))
        XCTAssertTrue(text.contains("成功 2 项"))
        XCTAssertTrue(text.contains("跳过 1 项"))
        XCTAssertTrue(text.contains("失败 1 项"))
        XCTAssertTrue(text.contains("1 个 skill 已不存在"))
    }
}
