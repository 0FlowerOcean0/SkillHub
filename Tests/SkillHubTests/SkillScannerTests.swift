import XCTest
@testable import SkillHub

/// 临时目录 fixture：所有文件系统测试都在 temporaryDirectory 下建独立沙盒，测试后清理。
final class TempSandbox {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("skillhub-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// 建一个 skill 目录（含 SKILL.md），返回目录 URL
    @discardableResult
    func makeSkillDir(_ relativePath: String, frontmatter: String? = nil, extraBody: String = "") throws -> URL {
        let dir = root.appendingPathComponent(relativePath, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var md = ""
        if let frontmatter {
            md += frontmatter
            if !frontmatter.hasSuffix("\n") { md += "\n" }
        }
        md += extraBody.isEmpty ? "# \(dir.lastPathComponent)\n" : extraBody
        try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    func makeTarget(_ id: String, _ relativePath: String) -> AgentTarget {
        AgentTarget(id: id, displayName: id, dir: root.appendingPathComponent(relativePath, isDirectory: true))
    }
}

final class SkillScannerTests: XCTestCase {

    func testScanDeduplicatesSymlinksToSameCanonical() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/alpha", frontmatter: "---\nname: alpha\ndescription: A\n---\n")
        let store = box.makeTarget("agents", "store/skills")
        let agentA = box.makeTarget("agentA", "a/skills")
        let agentB = box.makeTarget("agentB", "b/skills")
        try box.fm.createDirectory(at: agentA.dir, withIntermediateDirectories: true)
        try box.fm.createDirectory(at: agentB.dir, withIntermediateDirectories: true)
        try box.fm.createSymbolicLink(atPath: agentA.dir.appendingPathComponent("alpha").path,
                                      withDestinationPath: SkillOps.relativePath(from: agentA.dir, to: canonical))
        try box.fm.createSymbolicLink(atPath: agentB.dir.appendingPathComponent("alpha").path,
                                      withDestinationPath: SkillOps.relativePath(from: agentB.dir, to: canonical))

        let outcome = SkillScanner.scan(targets: [store, agentA, agentB])
        XCTAssertEqual(outcome.skills.count, 1, "同一本体应只出现一个 skill")
        let skill = outcome.skills[0]
        XCTAssertEqual(skill.name, "alpha")
        XCTAssertTrue(skill.hasFrontmatter)
        XCTAssertEqual(skill.descriptionText, "A")
        XCTAssertEqual(skill.presence["agents"], .real)
        XCTAssertEqual(skill.presence["agentA"], .symlink)
        XCTAssertEqual(skill.presence["agentB"], .symlink)
        XCTAssertTrue(outcome.brokenLinks.isEmpty)
    }

    func testScanDetectsBrokenLinks() throws {
        let box = try TempSandbox()
        let agent = box.makeTarget("agentA", "a/skills")
        try box.fm.createDirectory(at: agent.dir, withIntermediateDirectories: true)
        let ghost = box.root.appendingPathComponent("ghost/skill")
        try box.fm.createSymbolicLink(
            atPath: agent.dir.appendingPathComponent("dead").path,
            withDestinationPath: SkillOps.relativePath(from: agent.dir, to: ghost)
        )

        let outcome = SkillScanner.scan(targets: [agent])
        XCTAssertTrue(outcome.skills.isEmpty)
        XCTAssertEqual(outcome.brokenLinks.count, 1)
        XCTAssertEqual(outcome.brokenLinks[0].agentID, "agentA")
        XCTAssertEqual(outcome.brokenLinks[0].url.lastPathComponent, "dead")
    }

    func testScanIgnoresDirsWithoutSkillMarkdown() throws {
        let box = try TempSandbox()
        let store = box.makeTarget("agents", "store/skills")
        try box.fm.createDirectory(at: store.dir.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)
        _ = try box.makeSkillDir("store/skills/real-skill")

        let outcome = SkillScanner.scan(targets: [store])
        XCTAssertEqual(outcome.skills.map(\.name), ["real-skill"])
    }

    func testScanFallsBackToDirectoryNameAndExtractsAuthor() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/ljg-mything") // 无 frontmatter
        let store = box.makeTarget("agents", "store/skills")

        let outcome = SkillScanner.scan(targets: [store])
        XCTAssertEqual(outcome.skills.count, 1)
        XCTAssertEqual(outcome.skills[0].name, "ljg-mything")
        XCTAssertFalse(outcome.skills[0].hasFrontmatter)
        XCTAssertEqual(outcome.skills[0].author, "ljg")
    }

    func testScanCountsFilesAndSupportDirs() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/beta", frontmatter: "---\nname: beta\n---\n")
        try box.fm.createDirectory(at: dir.appendingPathComponent("references"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("references/r1.md"), atomically: true, encoding: .utf8)
        let store = box.makeTarget("agents", "store/skills")

        let outcome = SkillScanner.scan(targets: [store])
        let skill = outcome.skills[0]
        XCTAssertEqual(skill.fileCount, 2) // SKILL.md + references/r1.md
        XCTAssertTrue(skill.sizeBytes > 0)
        XCTAssertEqual(skill.supportDirs, ["references"])
    }

    func testScanSkipsNonexistentTargets() throws {
        let box = try TempSandbox()
        let missing = box.makeTarget("ghost", "no/such/dir")
        let outcome = SkillScanner.scan(targets: [missing])
        XCTAssertTrue(outcome.skills.isEmpty)
        XCTAssertTrue(outcome.brokenLinks.isEmpty)
    }
}
