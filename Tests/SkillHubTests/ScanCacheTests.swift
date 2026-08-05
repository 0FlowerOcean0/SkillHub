import XCTest
@testable import SkillHub

/// 扫描缓存（ScanCache + plan/execute 指纹复用）的单元测试。
final class ScanCacheTests: XCTestCase {

    /// 强制把某个路径的 mtime 改成一个确定不同的值，避免文件系统时间精度导致误判
    private func bumpMtime(_ url: URL, by seconds: TimeInterval = 120) throws {
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(seconds)],
            ofItemAtPath: url.path
        )
    }

    func testExecuteReusesCacheWhenFingerprintsUnchanged() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/alpha", frontmatter: "---\nname: alpha\ndescription: A\n---\n")
        let store = box.makeTarget("agents", "store/skills")

        // 第一次全量扫描，产出缓存
        let first = SkillScanner.execute(plan: SkillScanner.plan(targets: [store]), cache: nil)
        XCTAssertFalse(first.fullyFromCache)
        XCTAssertEqual(first.outcome.skills.map(\.name), ["alpha"])

        // 篡改缓存里的名字（指纹不动），如果复用缓存就会拿到假名字
        var tamperedEntries = first.cache.entries
        for (path, entry) in tamperedEntries {
            var e = entry
            e.name = "cached-\(entry.name)"
            tamperedEntries[path] = e
        }
        let tampered = ScanCache(version: ScanCache.formatVersion, entries: tamperedEntries)

        let plan = SkillScanner.plan(targets: [store])
        XCTAssertTrue(plan.fullyCovered(by: tampered))
        let second = SkillScanner.execute(plan: plan, cache: tampered)
        XCTAssertTrue(second.fullyFromCache, "指纹未变时不应重新解析")
        XCTAssertEqual(second.outcome.skills.map(\.name), ["cached-alpha"], "应原样复用缓存内容")
        XCTAssertEqual(second.outcome.skills[0].presence["agents"], .real, "presence 每次都要重新列举")
    }

    func testExecuteRescansSkillWhenMarkdownChanges() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/alpha", frontmatter: "---\nname: alpha\n---\n")
        _ = try box.makeSkillDir("store/skills/beta", frontmatter: "---\nname: beta\n---\n")
        let store = box.makeTarget("agents", "store/skills")

        let first = SkillScanner.execute(plan: SkillScanner.plan(targets: [store]), cache: nil)

        // 修改 alpha 的 SKILL.md，并确保 mtime 变化
        let md = dir.appendingPathComponent("SKILL.md")
        try "---\nname: alpha-v2\n---\n".write(to: md, atomically: true, encoding: .utf8)
        try bumpMtime(md)

        let plan = SkillScanner.plan(targets: [store])
        XCTAssertFalse(plan.fullyCovered(by: first.cache), "alpha 指纹变了，不应完整覆盖")
        let second = SkillScanner.execute(plan: plan, cache: first.cache)
        XCTAssertFalse(second.fullyFromCache)
        let names = second.outcome.skills.map(\.name)
        XCTAssertTrue(names.contains("alpha-v2"), "变化的 skill 应重新解析")
        XCTAssertTrue(names.contains("beta"), "未变化的 skill 仍在列表里")
    }

    func testExecuteRescansWhenDirectoryContentsChange() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/alpha", frontmatter: "---\nname: alpha\n---\n")
        let store = box.makeTarget("agents", "store/skills")

        let first = SkillScanner.execute(plan: SkillScanner.plan(targets: [store]), cache: nil)
        XCTAssertEqual(first.outcome.skills[0].fileCount, 1)

        // 新增一个文件（目录 mtime 变化）
        try "x".write(to: dir.appendingPathComponent("extra.md"), atomically: true, encoding: .utf8)
        try bumpMtime(dir)

        let second = SkillScanner.execute(plan: SkillScanner.plan(targets: [store]), cache: first.cache)
        XCTAssertFalse(second.fullyFromCache)
        XCTAssertEqual(second.outcome.skills[0].fileCount, 2)
    }

    func testPlanNotCoveredWhenNewSkillAppears() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/alpha")
        let store = box.makeTarget("agents", "store/skills")

        let first = SkillScanner.execute(plan: SkillScanner.plan(targets: [store]), cache: nil)
        XCTAssertTrue(SkillScanner.plan(targets: [store]).fullyCovered(by: first.cache))

        _ = try box.makeSkillDir("store/skills/gamma")
        XCTAssertFalse(SkillScanner.plan(targets: [store]).fullyCovered(by: first.cache),
                       "新增 skill 后缓存不应完整覆盖")
    }

    func testScanCacheSaveLoadRoundtrip() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("store/skills/alpha", frontmatter: "---\nname: alpha\nversion: 1.2.3\n---\n")
        let store = box.makeTarget("agents", "store/skills")
        let result = SkillScanner.execute(plan: SkillScanner.plan(targets: [store]), cache: nil)

        let url = box.root.appendingPathComponent("cache/scan.json")
        result.cache.save(to: url)
        let loaded = ScanCache.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.entries.count, 1)
        let entry = loaded?.entries.values.first
        XCTAssertEqual(entry?.name, "alpha")
        XCTAssertEqual(entry?.version, "1.2.3")

        // 格式版本不符时应拒绝加载
        let stale = ScanCache(version: -1, entries: result.cache.entries)
        stale.save(to: url)
        XCTAssertNil(ScanCache.load(from: url))
    }
}
