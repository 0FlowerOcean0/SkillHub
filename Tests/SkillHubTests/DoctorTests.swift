import XCTest
@testable import SkillHub

final class DoctorTests: XCTestCase {

    private func scan(_ box: TempSandbox, _ targets: [AgentTarget]) -> ScanOutcome {
        SkillScanner.scan(targets: targets)
    }

    func testBrokenLinkProducesError() throws {
        let box = try TempSandbox()
        let agent = box.makeTarget("agentA", "a/skills")
        try box.fm.createDirectory(at: agent.dir, withIntermediateDirectories: true)
        try box.fm.createSymbolicLink(
            atPath: agent.dir.appendingPathComponent("dead").path,
            withDestinationPath: "../ghost/nope"
        )
        let outcome = scan(box, [agent])
        let issues = Doctor.run(outcome: outcome, targets: [agent])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .error)
        if case .deleteBrokenLink(let url) = issues[0].fixAction {
            XCTAssertEqual(url.lastPathComponent, "dead")
        } else {
            XCTFail("期望 deleteBrokenLink 修复动作，实际 \(issues[0].fixAction)")
        }
    }

    func testMissingFrontmatterAndMissingDescription() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/no-fm") // 无 frontmatter -> error
        _ = try box.makeSkillDir("store/skills/no-desc", frontmatter: "---\nname: no-desc\n---\n") // 无 description -> warning
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")

        let issues = Doctor.run(outcome: scan(box, [store]), targets: [store])
        let noFM = issues.filter { $0.skillName == "no-fm" }
        XCTAssertTrue(noFM.contains { $0.severity == .error && $0.title.contains("缺少 frontmatter") })

        let noDesc = issues.filter { $0.skillName == "no-desc" }
        XCTAssertTrue(noDesc.contains { $0.severity == .warning && $0.title.contains("缺少 description") })
        // 有 frontmatter 的 skill 不应报"缺少 frontmatter"
        XCTAssertFalse(noDesc.contains { $0.title.contains("缺少 frontmatter") })
    }

    func testFolderNameMismatchProducesInfo() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/dirname", frontmatter: "---\nname: realname\ndescription: d\n---\n")
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")

        let issues = Doctor.run(outcome: scan(box, [store]), targets: [store])
        XCTAssertTrue(issues.contains {
            $0.severity == .info && $0.title.contains("目录名") && $0.title.contains("不一致")
        })
    }

    func testMissingReferenceDetected() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir(
            "store/skills/refs",
            frontmatter: "---\nname: refs\ndescription: d\n---\n",
            extraBody: "见 references/missing.md 和 references/exists.md\n"
        )
        let dir = box.root.appendingPathComponent("store/skills/refs")
        try box.fm.createDirectory(at: dir.appendingPathComponent("references"), withIntermediateDirectories: true)
        try "ok".write(to: dir.appendingPathComponent("references/exists.md"), atomically: true, encoding: .utf8)
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")

        let skill = scan(box, [store]).skills[0]
        let missing = Doctor.missingReferences(skill: skill)
        XCTAssertEqual(missing, ["references/missing.md"], "存在的引用不应报缺失")
    }

    func testURLInBodyIsNotTreatedAsReference() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir(
            "store/skills/urlref",
            frontmatter: "---\nname: urlref\ndescription: d\n---\n",
            extraBody: "下载 https://example.com/references/pack.zip 后使用\n"
        )
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")
        let skill = scan(box, [store]).skills[0]
        XCTAssertTrue(Doctor.missingReferences(skill: skill).isEmpty, "URL 里的路径片段不应误判为相对引用")
    }

    func testOrphanSkillDetectedOnlyWhenInCanonicalStore() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/lonely", frontmatter: "---\nname: lonely\ndescription: d\n---\n")
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")
        let agent = box.makeTarget("agentA", "a/skills")
        try box.fm.createDirectory(at: agent.dir, withIntermediateDirectories: true)

        let issues = Doctor.run(outcome: scan(box, [store, agent]), targets: [store, agent])
        XCTAssertTrue(issues.contains { $0.skillName == "lonely" && $0.title.contains("未被任何 agent 启用") })
    }

    func testBodyOutsideStoreTriggersMigrateSuggestion() throws {
        let box = try TempSandbox()
        // 本体直接放在 agent 目录里，不在 canonical store
        _ = try box.makeSkillDir("a/skills/local-only", frontmatter: "---\nname: local-only\ndescription: d\n---\n")
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")
        try box.fm.createDirectory(at: store.dir, withIntermediateDirectories: true)
        let agent = box.makeTarget("agentA", "a/skills")

        let issues = Doctor.run(outcome: scan(box, [store, agent]), targets: [store, agent])
        let migrate = issues.filter { $0.skillName == "local-only" && $0.title.contains("本体不在本体库") }
        XCTAssertEqual(migrate.count, 1)
        if case .migrateToStore(_, let agentID) = migrate[0].fixAction {
            XCTAssertEqual(agentID, "agentA")
        } else {
            XCTFail("期望 migrateToStore 修复动作")
        }
    }

    func testSiblingDirectoryWithSamePrefixNotTreatedAsInsideStore() throws {
        let box = try TempSandbox()
        // store 为 store/skills，本体在 store/skills2 下：不应被认为在本体库内
        _ = try box.makeSkillDir("store/skills2/outside", frontmatter: "---\nname: outside\ndescription: d\n---\n")
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")
        try box.fm.createDirectory(at: store.dir, withIntermediateDirectories: true)
        let agent = box.makeTarget("agentA", "store/skills2")

        let issues = Doctor.run(outcome: scan(box, [store, agent]), targets: [store, agent])
        XCTAssertTrue(issues.contains { $0.skillName == "outside" && $0.title.contains("本体不在本体库") })
    }

    func testIssuesSortedBySeverity() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/no-fm") // error
        _ = try box.makeSkillDir("store/skills/no-desc", frontmatter: "---\nname: no-desc\n---\n") // warning
        let store = box.makeTarget(AgentTarget.canonicalID, "store/skills")

        let issues = Doctor.run(outcome: scan(box, [store]), targets: [store])
        for (a, b) in zip(issues, issues.dropFirst()) {
            XCTAssertLessThanOrEqual(a.severity, b.severity)
        }
    }
}
