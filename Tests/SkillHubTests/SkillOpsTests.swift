import XCTest
@testable import SkillHub

final class SkillOpsTests: XCTestCase {

    // MARK: - relativePath

    func testRelativePathSiblingDirs() {
        let from = URL(fileURLWithPath: "/Users/x/.claude/skills")
        let to = URL(fileURLWithPath: "/Users/x/.agents/skills/foo")
        XCTAssertEqual(SkillOps.relativePath(from: from, to: to), "../../.agents/skills/foo")
    }

    func testRelativePathChildAndSelf() {
        let base = URL(fileURLWithPath: "/a/b")
        XCTAssertEqual(SkillOps.relativePath(from: base, to: URL(fileURLWithPath: "/a/b/c")), "c")
        XCTAssertEqual(SkillOps.relativePath(from: base, to: base), ".")
    }

    func testRelativePathNoCommonPrefix() {
        let from = URL(fileURLWithPath: "/x/y")
        let to = URL(fileURLWithPath: "/p/q/r")
        XCTAssertEqual(SkillOps.relativePath(from: from, to: to), "../../p/q/r")
    }

    // MARK: - enable / disable（临时目录 fixture）

    func testEnableCreatesWorkingSymlinkAndDisableRemovesIt() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/gamma", frontmatter: "---\nname: gamma\n---\n")
        let target = box.makeTarget("agentA", "a/skills")

        var skill = Skill(name: "gamma", descriptionText: "", version: nil, canonicalPath: canonical)

        try SkillOps.enable(skill: skill, in: target)
        let link = target.dir.appendingPathComponent("gamma")
        // 软链接应解析回本体
        XCTAssertEqual(link.resolvingSymlinksInPath().standardizedFileURL.path,
                       canonical.standardizedFileURL.path)

        // 重复 enable 应报错
        XCTAssertThrowsError(try SkillOps.enable(skill: skill, in: target))

        skill.presence["agentA"] = .symlink
        try SkillOps.disable(skill: skill, in: target)
        XCTAssertFalse(box.fm.fileExists(atPath: link.path))
        // 本体仍在
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.appendingPathComponent("SKILL.md").path))
    }

    func testDisableRefusesRealDirectory() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("a/skills/real", frontmatter: "---\nname: real\n---\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "real", descriptionText: "", version: nil, canonicalPath: canonical)

        XCTAssertThrowsError(try SkillOps.disable(skill: skill, in: target)) { error in
            XCTAssertTrue(error.localizedDescription.contains("本体"))
        }
        // 真实目录必须还在
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.path))
    }

    // MARK: - addFrontmatter / addDescription

    func testAddFrontmatterPrependsBlock() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/plain", extraBody: "# plain\nbody text\n")
        let md = dir.appendingPathComponent("SKILL.md")

        try SkillOps.addFrontmatter(to: md)
        let parsed = FrontmatterParser.parse(fileURL: md)
        XCTAssertTrue(parsed.hasFrontmatter)
        XCTAssertEqual(parsed.name, "plain")

        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(text.contains("# plain"), "正文必须保留")
    }

    func testAddDescriptionInsertsAfterName() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/d", frontmatter: "---\nname: d\n---\n")
        let md = dir.appendingPathComponent("SKILL.md")

        try SkillOps.addDescription(to: md, description: "新描述")
        let parsed = FrontmatterParser.parse(fileURL: md)
        XCTAssertEqual(parsed.descriptionText, "新描述")
        XCTAssertEqual(parsed.name, "d")
    }

    // MARK: - renameDirectory

    func testRenameDirectoryUpdatesQuotedName() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/old", frontmatter: "---\nname: \"old\"\ndescription: d\n---\n")
        try SkillOps.renameDirectory(from: dir, to: "new")

        let newDir = box.root.appendingPathComponent("store/skills/new")
        XCTAssertTrue(box.fm.fileExists(atPath: newDir.path))
        XCTAssertFalse(box.fm.fileExists(atPath: dir.path))
        let parsed = FrontmatterParser.parse(fileURL: newDir.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(parsed.name, "new")
    }

    func testRenameDirectoryUpdatesUnquotedNameAndKeepsBody() throws {
        let body = "正文里提到 name: something 不应被改动\n"
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/old2",
                                       frontmatter: "---\nname: old2\ndescription: d\n---\n",
                                       extraBody: body)
        try SkillOps.renameDirectory(from: dir, to: "new2")

        let md = box.root.appendingPathComponent("store/skills/new2/SKILL.md")
        let parsed = FrontmatterParser.parse(fileURL: md)
        XCTAssertEqual(parsed.name, "new2", "无引号的 name 也要更新")
        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(text.contains("name: something"), "正文中的 name: 不应被修改")
    }

    func testRenameDirectoryFailsIfTargetExists() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/a1")
        _ = try box.makeSkillDir("store/skills/a2")
        XCTAssertThrowsError(try SkillOps.renameDirectory(from: dir, to: "a2"))
        XCTAssertTrue(box.fm.fileExists(atPath: dir.path), "失败后源目录应保持不变")
    }

    // MARK: - removeReference

    func testRemoveReferenceDropsOnlyMatchingLines() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir(
            "store/skills/r",
            frontmatter: "---\nname: r\ndescription: d\n---\n",
            extraBody: "看 references/gone.md 这个文件\n另一行 references/kept.md 保留\n"
        )
        let md = dir.appendingPathComponent("SKILL.md")
        try SkillOps.removeReference(from: md, reference: "references/gone.md")

        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertFalse(text.contains("references/gone.md"))
        XCTAssertTrue(text.contains("references/kept.md"))
        XCTAssertTrue(FrontmatterParser.parse(fileURL: md).hasFrontmatter)
    }

    // MARK: - migrateToStore（一键收编）

    func testMigrateToStoreWithCustomTargetRelinks() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("customAgent/skills/omega", frontmatter: "---\nname: omega\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let customTarget = box.makeTarget("custom_x", "customAgent/skills")

        try SkillOps.migrateToStore(skillPath: stray, target: customTarget, storeDir: storeDir)

        let dest = storeDir.appendingPathComponent("omega")
        XCTAssertTrue(box.fm.fileExists(atPath: dest.path), "本体应移动到本体库")
        // 原位置的本体目录应被替换为软链（路径仍在，但已是指回本体的链接）
        let link = customTarget.dir.appendingPathComponent("omega")
        XCTAssertEqual((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink, true,
                       "原位置应留下软链而非真实目录")
        // 软链应解析回本体
        XCTAssertEqual(link.resolvingSymlinksInPath().standardizedFileURL.path,
                       dest.standardizedFileURL.path)
    }

    func testMigrateToStoreWithoutTargetOnlyMoves() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("elsewhere/delta", frontmatter: "---\nname: delta\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)

        try SkillOps.migrateToStore(skillPath: stray, target: nil, storeDir: storeDir)

        XCTAssertTrue(box.fm.fileExists(atPath: storeDir.appendingPathComponent("delta").path))
        XCTAssertFalse(box.fm.fileExists(atPath: stray.path))
    }

    func testMigrateToStoreFailsOnNameConflict() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("agentB/skills/dup", frontmatter: "---\nname: dup\n---\n")
        _ = try box.makeSkillDir("store/skills/dup", frontmatter: "---\nname: dup\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)

        XCTAssertThrowsError(try SkillOps.migrateToStore(skillPath: stray, target: nil, storeDir: storeDir))
        XCTAssertTrue(box.fm.fileExists(atPath: stray.path), "冲突时源目录应保持不变")
    }

    // MARK: - relinkToStore（同名冲突的链接化处理）

    func testRelinkToStoreTrashesStrayAndCreatesSymlink() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("agentC/skills/echo", frontmatter: "---\nname: echo\n---\n")
        let stored = try box.makeSkillDir("store/skills/echo", frontmatter: "---\nname: echo\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let target = box.makeTarget("agentC", "agentC/skills")

        try SkillOps.relinkToStore(skillPath: stray, target: target, storeDir: storeDir)

        // 原位置变成指向本体库版本的软链（用新 URL 实例判断，避免 resourceValues 缓存）
        let freshStray = URL(fileURLWithPath: stray.path)
        XCTAssertEqual((try? freshStray.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink, true)
        XCTAssertEqual(freshStray.resolvingSymlinksInPath().standardizedFileURL.path,
                       stored.standardizedFileURL.path)
        // 本体库版本不受影响
        XCTAssertTrue(box.fm.fileExists(atPath: stored.appendingPathComponent("SKILL.md").path))
    }

    func testRelinkToStoreRequiresStoreVersion() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("agentC/skills/lonely", frontmatter: "---\nname: lonely\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let target = box.makeTarget("agentC", "agentC/skills")

        XCTAssertThrowsError(try SkillOps.relinkToStore(skillPath: stray, target: target, storeDir: storeDir))
        XCTAssertTrue(box.fm.fileExists(atPath: stray.appendingPathComponent("SKILL.md").path),
                      "失败时散落目录应保持不变")
    }
}
