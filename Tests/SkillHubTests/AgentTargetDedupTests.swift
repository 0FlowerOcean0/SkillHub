import XCTest
@testable import SkillHub

final class AgentTargetDedupTests: XCTestCase {

    private func target(_ id: String, _ path: String) -> AgentTarget {
        AgentTarget(id: id, displayName: id, dir: URL(fileURLWithPath: path))
    }

    func testDeduplicatesSameDirectoryWithDifferentIDs() {
        // 内置 "claude" 与自动检测的 "auto_claude" 指向同一目录，只保留先出现的内置项
        let list = [
            target("claude", "/Users/x/.claude/skills"),
            target("auto_claude", "/Users/x/.claude/skills"),
            target("qoder", "/Users/x/.qoder/skills"),
        ]
        let result = AgentTarget.deduplicatedByDirectory(list)
        XCTAssertEqual(result.map(\.id), ["claude", "qoder"])
    }

    func testTrailingSlashTreatedAsSameDirectory() {
        let list = [
            target("claude", "/Users/x/.claude/skills"),
            target("auto_claude", "/Users/x/.claude/skills/"),
        ]
        let result = AgentTarget.deduplicatedByDirectory(list)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "claude")
    }

    func testDistinctDirectoriesAreKept() {
        let list = [
            target("claude", "/Users/x/.claude/skills"),
            target("roo", "/Users/x/.roo/skills"),
        ]
        XCTAssertEqual(AgentTarget.deduplicatedByDirectory(list).count, 2)
    }

    func testRootPathTrailingSlashNotOverStripped() {
        // 根目录 "/" 不应被裁成空字符串
        let list = [
            target("a", "/"),
            target("b", "/"),
            target("c", "/tmp/skills"),
        ]
        let result = AgentTarget.deduplicatedByDirectory(list)
        XCTAssertEqual(result.map(\.id), ["a", "c"])
    }
}
