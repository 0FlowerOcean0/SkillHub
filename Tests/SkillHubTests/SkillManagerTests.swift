import XCTest
@testable import SkillHub

final class SkillManagerTests: XCTestCase {

    private func makeSkill(
        name: String,
        description: String = "",
        tags: [String] = [],
        author: String = "",
        path: String = "/tmp/\(UUID().uuidString)"
    ) -> Skill {
        var s = Skill(
            name: name,
            descriptionText: description,
            version: nil,
            canonicalPath: URL(fileURLWithPath: path)
        )
        s.tags = tags
        s.author = author
        return s
    }

    // MARK: - fuzzyMatch（通过 search 间接测试）

    func testFuzzyMatchSubsequenceSemantics() {
        // query="abc" vs text="abx"：c 不存在，不应匹配（旧实现的 bug）
        let bad = makeSkill(name: "abx")
        let results = SkillManager.search(skills: [bad], query: "abc")
        XCTAssertTrue(results.isEmpty, "abx 不应模糊匹配 abc")

        // query 是 text 的真子序列：应匹配
        let good = makeSkill(name: "axbxc")
        let results2 = SkillManager.search(skills: [good], query: "abc")
        XCTAssertEqual(results2.count, 1)
        XCTAssertEqual(results2.first?.matchReason, "模糊匹配")

        // 顺序颠倒不匹配
        let reversed = makeSkill(name: "cbaxy")
        XCTAssertTrue(SkillManager.search(skills: [reversed], query: "abc").isEmpty)
    }

    func testFuzzyMatchUnicode() {
        let s = makeSkill(name: "写个文档")
        XCTAssertEqual(SkillManager.search(skills: [s], query: "写档").count, 1)
        XCTAssertTrue(SkillManager.search(skills: [s], query: "档写").isEmpty)
    }

    // MARK: - search 评分与排序

    func testSearchScoringOrder() {
        let exact = makeSkill(name: "deploy")
        let contains = makeSkill(name: "deploy-tool")
        let desc = makeSkill(name: "other", description: "helps deploy stuff")
        let tag = makeSkill(name: "another", tags: ["deployment"])
        let none = makeSkill(name: "zzz", description: "nothing here")

        let results = SkillManager.search(
            skills: [none, tag, desc, contains, exact],
            query: "deploy"
        )
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results[0].skill.name, "deploy")       // 1.0 精确
        XCTAssertEqual(results[1].skill.name, "deploy-tool")  // 0.9 名称包含
        XCTAssertEqual(results[2].skill.name, "other")        // 0.7 描述
        XCTAssertEqual(results[3].skill.name, "another")      // 0.6 标签
        XCTAssertTrue(results[0].score > results[1].score)
        XCTAssertTrue(results[1].score > results[2].score)
        XCTAssertTrue(results[2].score > results[3].score)
    }

    func testSearchEmptyQueryReturnsAll() {
        let skills = [makeSkill(name: "a"), makeSkill(name: "b")]
        let results = SkillManager.search(skills: skills, query: "   ")
        XCTAssertEqual(results.count, 2)
    }

    func testSearchCaseInsensitive() {
        let s = makeSkill(name: "CodeReview")
        let results = SkillManager.search(skills: [s], query: "codereview")
        XCTAssertEqual(results.first?.score, 1.0)
    }

    // MARK: - categorize

    func testCategorize() {
        let writing = makeSkill(name: "blog-writer", description: "写文章")
        let coding = makeSkill(name: "code-reviewer", description: "review code")
        let data = makeSkill(name: "data-analyzer", description: "数据分析")
        let comm = makeSkill(name: "email-sender", description: "send email")
        let creative = makeSkill(name: "logo-designer", description: "design images")
        let other = makeSkill(name: "xyzzy", description: "plugh")

        let groups = SkillManager.categorize(skills: [writing, coding, data, comm, creative, other])
        let byCat = Dictionary(uniqueKeysWithValues: groups.map { ($0.category, $0.skills.map(\.name)) })

        XCTAssertEqual(byCat[.writing], ["blog-writer"])
        XCTAssertEqual(byCat[.coding], ["code-reviewer"])
        XCTAssertEqual(byCat[.data], ["data-analyzer"])
        XCTAssertEqual(byCat[.communication], ["email-sender"])
        XCTAssertEqual(byCat[.creative], ["logo-designer"])
        XCTAssertEqual(byCat[.other], ["xyzzy"])
    }

    func testCategorizeEmptyInput() {
        XCTAssertTrue(SkillManager.categorize(skills: []).isEmpty)
    }

    func testCategorizeByTag() {
        let s = makeSkill(name: "misc", tags: ["翻译"])
        let groups = SkillManager.categorize(skills: [s])
        XCTAssertEqual(groups.first?.category, .writing)
    }

    // MARK: - isPath(inside:)

    func testIsPathInside() {
        let store = URL(fileURLWithPath: "/Users/x/.agents/skills")
        XCTAssertTrue(SkillManager.isPath(URL(fileURLWithPath: "/Users/x/.agents/skills/foo"), inside: store))
        XCTAssertTrue(SkillManager.isPath(store, inside: store))
        // 兄弟目录前缀相同但不是子路径（旧 hasPrefix 实现的 bug）
        XCTAssertFalse(SkillManager.isPath(URL(fileURLWithPath: "/Users/x/.agents/skills2/foo"), inside: store))
        XCTAssertFalse(SkillManager.isPath(URL(fileURLWithPath: "/Users/x/other/foo"), inside: store))
    }

    // MARK: - groupByAuthor

    /// 造 n 个同作者 skill
    private func makeSkills(author: String, count: Int, namePrefix: String) -> [Skill] {
        (0..<count).map { makeSkill(name: "\(namePrefix)-\($0)", author: author) }
    }

    func testGroupByAuthorSortsNormalMiscUnknown() {
        // alice 达到阈值单独成组；bob 不足阈值归入"其他"；空串为"未知作者"
        let skills = makeSkills(author: "alice", count: 3, namePrefix: "a")
            + makeSkills(author: "bob", count: 1, namePrefix: "b")
            + [makeSkill(name: "anon", author: "")]
        let groups = SkillManager.groupByAuthor(skills: skills)
        XCTAssertEqual(groups.map(\.author), ["alice", SkillManager.miscAuthorGroupID, ""])
        XCTAssertEqual(groups.last?.displayName, "未知作者")
    }

    func testGroupByAuthorThresholdGrouping() {
        // 恰好等于阈值 3 应单独成组
        let skills = makeSkills(author: "carol", count: SkillManager.authorGroupMinCount, namePrefix: "c")
        let groups = SkillManager.groupByAuthor(skills: skills)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.author, "carol")
        XCTAssertEqual(groups.first?.isMisc, false)
        XCTAssertEqual(groups.first?.skills.count, 3)
    }

    func testGroupByAuthorBelowThresholdMerged() {
        // 差 1 个不到阈值：不成组，归入"其他"
        let skills = makeSkills(author: "dave", count: SkillManager.authorGroupMinCount - 1, namePrefix: "d")
        let groups = SkillManager.groupByAuthor(skills: skills)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups.first?.isMisc == true)
        XCTAssertEqual(groups.first?.displayName, "其他")
        XCTAssertEqual(groups.first?.skills.count, SkillManager.authorGroupMinCount - 1)
    }

    func testGroupByAuthorMiscContainsMultipleAuthors() {
        // "其他"组应包含多个不同作者的 skills
        let skills = makeSkills(author: "erin", count: 2, namePrefix: "e")
            + makeSkills(author: "frank", count: 1, namePrefix: "f")
        let groups = SkillManager.groupByAuthor(skills: skills)
        XCTAssertEqual(groups.count, 1)
        let misc = groups[0]
        XCTAssertTrue(misc.isMisc)
        XCTAssertEqual(misc.skills.count, 3)
        XCTAssertEqual(Set(misc.skills.map(\.author)), ["erin", "frank"])
    }

    func testGroupByAuthorAllBelowThresholdOnlyMiscAndUnknown() {
        // 所有作者都不足阈值：应只剩"其他"和"未知作者"
        let skills = makeSkills(author: "gina", count: 1, namePrefix: "g")
            + makeSkills(author: "hank", count: 2, namePrefix: "h")
            + makeSkills(author: "", count: 1, namePrefix: "u")
        let groups = SkillManager.groupByAuthor(skills: skills)
        XCTAssertEqual(groups.map(\.isMisc), [true, false])
        XCTAssertEqual(groups[1].author, "")
    }

    func testGroupByAuthorEmptyInput() {
        XCTAssertTrue(SkillManager.groupByAuthor(skills: []).isEmpty)
    }

    // MARK: - isRepresentedInStore（本体库收纳判断）

    func testRepresentedInStoreWhenBodyInside() throws {
        let box = try TempSandbox()
        let body = try box.makeSkillDir("store/skills/inside", frontmatter: "---\nname: inside\n---\n")
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let skill = makeSkill(name: "inside", path: body.path)
        XCTAssertTrue(SkillManager.isRepresentedInStore(skill: skill, storeDir: store))
    }

    func testRepresentedInStoreWhenSymlinkResolvesToSameBody() throws {
        let box = try TempSandbox()
        // 本体在外部目录（模拟 iCloud），本体库用软链登记
        let external = try box.makeSkillDir("icloud/skills/linked", frontmatter: "---\nname: linked\n---\n")
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        try box.fm.createDirectory(at: store, withIntermediateDirectories: true)
        try box.fm.createSymbolicLink(at: store.appendingPathComponent("linked"),
                                      withDestinationURL: external)
        let skill = makeSkill(name: "linked", path: external.path)
        XCTAssertTrue(SkillManager.isRepresentedInStore(skill: skill, storeDir: store),
                      "库内软链指向同一本体应视为已收纳")
    }

    func testNotRepresentedWhenAbsentOrPointsElsewhere() throws {
        let box = try TempSandbox()
        let external = try box.makeSkillDir("icloud/skills/ghost", frontmatter: "---\nname: ghost\n---\n")
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        try box.fm.createDirectory(at: store, withIntermediateDirectories: true)
        let skill = makeSkill(name: "ghost", path: external.path)

        // 库内完全没有同名入口
        XCTAssertFalse(SkillManager.isRepresentedInStore(skill: skill, storeDir: store))

        // 库内有同名软链但指向另一个本体
        let other = try box.makeSkillDir("elsewhere/ghost", frontmatter: "---\nname: ghost\n---\n")
        try box.fm.createSymbolicLink(at: store.appendingPathComponent("ghost"),
                                      withDestinationURL: other)
        XCTAssertFalse(SkillManager.isRepresentedInStore(skill: skill, storeDir: store),
                       "同名软链指向别的本体不应视为已收纳")
    }
}
