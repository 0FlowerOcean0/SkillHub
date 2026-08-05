import XCTest
@testable import SkillHub

final class FrontmatterParserTests: XCTestCase {

    func testNormalFrontmatter() {
        let md = """
        ---
        name: my-skill
        description: 一个测试 skill
        version: 1.2.3
        author: ljg
        ---
        # Body
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertTrue(r.hasFrontmatter)
        XCTAssertEqual(r.name, "my-skill")
        XCTAssertEqual(r.descriptionText, "一个测试 skill")
        XCTAssertEqual(r.version, "1.2.3")
        XCTAssertEqual(r.author, "ljg")
    }

    func testMissingFrontmatter() {
        let r = FrontmatterParser.parse(markdown: "# Just a heading\nno frontmatter here")
        XCTAssertFalse(r.hasFrontmatter)
        XCTAssertNil(r.name)
        XCTAssertNil(r.descriptionText)
        XCTAssertEqual(r.tags, [])
    }

    func testQuotedValuesAreUnwrapped() {
        let md = """
        ---
        name: "quoted-name"
        description: 'single quoted'
        ---
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertEqual(r.name, "quoted-name")
        XCTAssertEqual(r.descriptionText, "single quoted")
    }

    func testDashArrayAndInlineArray() {
        let md = """
        ---
        name: a
        tags:
          - swift
          - macos
        labels: [x, "y", 'z']
        ---
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertEqual(r.tags, ["swift", "macos"])
        XCTAssertEqual(r.arrays["labels"], ["x", "y", "z"])
    }

    func testMetadataSubfields() {
        let md = """
        ---
        name: a
        metadata:
          version: 2.0
          author: nested-author
        ---
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertEqual(r.version, "2.0")
        XCTAssertEqual(r.author, "nested-author")
    }

    func testFoldedBlockScalar() {
        let md = """
        ---
        name: a
        description: >
          第一行
          第二行
        ---
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertTrue(r.hasFrontmatter)
        XCTAssertEqual(r.descriptionText, "第一行 第二行")
    }

    func testFoldedBlockContainingDashesDoesNotEndFrontmatter() {
        // 折叠块内容里的缩进 --- 不应被当作 frontmatter 结束标记
        let md = """
        ---
        name: a
        description: |
          line one
          ---
          line two
        version: 1.0
        ---
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertTrue(r.hasFrontmatter)
        XCTAssertEqual(r.version, "1.0")
        XCTAssertEqual(r.descriptionText, "line one --- line two")
    }

    func testUnclosedFrontmatterKeepsParsedFieldsButFlagFalse() {
        let md = """
        ---
        name: orphan
        description: no closing marker
        # body follows
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertFalse(r.hasFrontmatter)
        XCTAssertEqual(r.name, "orphan")
        XCTAssertEqual(r.descriptionText, "no closing marker")
    }

    func testGarbageLinesAreIgnored() {
        let md = """
        ---
        not a key value line
        name: real
        :::
        ---
        """
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertTrue(r.hasFrontmatter)
        XCTAssertEqual(r.name, "real")
    }

    func testEmptyFileAndOnlyMarker() {
        XCTAssertFalse(FrontmatterParser.parse(markdown: "").hasFrontmatter)
        XCTAssertFalse(FrontmatterParser.parse(markdown: "---").hasFrontmatter)
    }

    func testCRLFLineEndings() {
        let md = "---\r\nname: crlf\r\ndescription: windows\r\n---\r\nbody"
        let r = FrontmatterParser.parse(markdown: md)
        XCTAssertTrue(r.hasFrontmatter)
        XCTAssertEqual(r.name, "crlf")
    }

    func testParseFileURLMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/SKILL.md")
        let r = FrontmatterParser.parse(fileURL: url)
        XCTAssertFalse(r.hasFrontmatter)
        XCTAssertNil(r.name)
    }
}
