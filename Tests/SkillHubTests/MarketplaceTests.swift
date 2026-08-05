import XCTest
@testable import SkillHub

/// 技能市场解析层测试：全部用内联 fixture，不触网
final class MarketplaceTests: XCTestCase {

    // MARK: - /api/search JSON 解析

    /// 正常响应（结构取自 https://skills.sh/api/search?q=pdf 的真实返回）
    func testParseSearchResults() throws {
        let json = """
        {
          "query": "pdf",
          "searchType": "fuzzy",
          "skills": [
            {"id":"anthropics/skills/pdf","skillId":"pdf","name":"pdf","installs":172670,"source":"anthropics/skills"},
            {"id":"vercel-labs/json-render/react-pdf","skillId":"react-pdf","name":"react-pdf","installs":1735,"source":"vercel-labs/json-render"}
          ]
        }
        """
        let skills = try MarketplaceParser.parseSearchResults(data: Data(json.utf8))
        XCTAssertEqual(skills.count, 2)

        let first = skills[0]
        XCTAssertEqual(first.id, "anthropics/skills/pdf")
        XCTAssertEqual(first.name, "pdf")
        XCTAssertEqual(first.owner, "anthropics")
        XCTAssertEqual(first.source, "anthropics/skills")
        XCTAssertEqual(first.installs, 172670)
        XCTAssertNil(first.description)
        XCTAssertEqual(first.skillPageURL.absoluteString, "https://skills.sh/anthropics/skills/pdf")
        XCTAssertEqual(first.repoURL.absoluteString, "https://github.com/anthropics/skills")
    }

    /// 服务端业务错误（query 太短）要抛 .server
    func testParseSearchResultsErrorPayload() {
        let json = #"{"error":"Query must be at least 2 characters"}"#
        XCTAssertThrowsError(try MarketplaceParser.parseSearchResults(data: Data(json.utf8))) { error in
            guard case MarketplaceError.server(let msg) = error else {
                return XCTFail("期望 server 错误，实际：\(error)")
            }
            XCTAssertTrue(msg.contains("2 characters"))
        }
    }

    /// 容错：installs 缺失 -> nil；缺 id / source 的条目被跳过；name 缺失时回退 skillId
    func testParseSearchResultsToleratesMissingFields() throws {
        let json = """
        {
          "query": "x",
          "searchType": "fuzzy",
          "skills": [
            {"id":"a/b/no-installs","skillId":"no-installs","name":"no-installs","source":"a/b"},
            {"skillId":"missing-id","name":"missing-id","installs":1,"source":"a/b"},
            {"id":"a/b/missing-source","skillId":"s","name":"s","installs":2},
            {"id":"a/b/fallback-name","skillId":"fallback-name","installs":3,"source":"a/b"}
          ]
        }
        """
        let skills = try MarketplaceParser.parseSearchResults(data: Data(json.utf8))
        XCTAssertEqual(skills.map(\.id), ["a/b/no-installs", "a/b/fallback-name"])
        XCTAssertNil(skills[0].installs)
        XCTAssertEqual(skills[1].name, "fallback-name")
    }

    /// 非 JSON 响要抛 .decoding
    func testParseSearchResultsInvalidData() {
        XCTAssertThrowsError(try MarketplaceParser.parseSearchResults(data: Data("<html>nope</html>".utf8))) { error in
            guard case MarketplaceError.decoding = error else {
                return XCTFail("期望 decoding 错误，实际：\(error)")
            }
        }
    }

    // MARK: - 首页 leaderboard HTML 解析

    /// 结构取自 https://skills.sh 首页真实条目的简化版
    func testParseLeaderboard() {
        let html = """
        <html><body>
        <div class="h-[72px] lg:h-[56px]"><a class="group grid grid-cols-[auto_1fr_auto] items-start gap-3" href="/anthropics/skills/webapp-testing"><div class="min-w-7"><span class="text-sm lg:text-base text-(--ds-gray-600) font-mono">1</span></div><div class="min-w-1 flex flex-col"><h3 class="font-semibold text-foreground truncate whitespace-nowrap">webapp-testing</h3><p class="text-xs lg:text-sm text-(--ds-gray-600) font-mono mt-0.5 truncate">anthropics/skills</p></div><div class="text-right flex items-center justify-end gap-2"><span class="font-mono text-sm text-foreground">129.5K</span></div></a></div>
        <div class="h-[72px]"><a class="group grid" href="/obra/superpowers/test-driven-development"><div><span class="text-sm lg:text-base text-(--ds-gray-600) font-mono">2</span></div><div><h3 class="font-semibold text-foreground truncate whitespace-nowrap">test-driven-development</h3><p class="truncate">obra/superpowers</p></div><div><span class="font-mono text-sm text-foreground">188.5K</span></div></a></div>
        <a href="/about">导航链接不应被解析</a>
        <a href="/docs/api/reference">三段路径但无 h3，也不应被解析</a>
        </body></html>
        """
        let skills = MarketplaceParser.parseLeaderboard(data: Data(html.utf8))
        XCTAssertEqual(skills.count, 2)

        XCTAssertEqual(skills[0].id, "anthropics/skills/webapp-testing")
        XCTAssertEqual(skills[0].name, "webapp-testing")
        XCTAssertEqual(skills[0].source, "anthropics/skills")
        XCTAssertEqual(skills[0].owner, "anthropics")
        XCTAssertEqual(skills[0].installs, 129_500)

        XCTAssertEqual(skills[1].id, "obra/superpowers/test-driven-development")
        XCTAssertEqual(skills[1].installs, 188_500)
    }

    /// 空 HTML / 非 UTF-8 容错
    func testParseLeaderboardEmpty() {
        XCTAssertTrue(MarketplaceParser.parseLeaderboard(data: Data()).isEmpty)
        XCTAssertTrue(MarketplaceParser.parseLeaderboard(data: Data([0xFF, 0xFE, 0x00])).isEmpty)
    }

    // MARK: - 详情页描述解析

    func testParseSkillDescription() {
        let html = """
        <html><head>
        <meta property="og:description" content="Toolkit for interacting with &amp; testing local web apps.">
        </head><body></body></html>
        """
        let desc = MarketplaceParser.parseSkillDescription(data: Data(html.utf8))
        XCTAssertEqual(desc, "Toolkit for interacting with & testing local web apps.")
    }

    /// content 在 property 之前的属性顺序也要能解析
    func testParseSkillDescriptionReversedAttributes() {
        let html = #"<meta content="Use when writing tests." property="og:description"/>"#
        XCTAssertEqual(MarketplaceParser.parseSkillDescription(data: Data(html.utf8)), "Use when writing tests.")
    }

    /// 无 og:description 时回退 name="description"；都没有则 nil
    func testParseSkillDescriptionFallback() {
        let fallback = #"<meta name="description" content="fallback desc">"#
        XCTAssertEqual(MarketplaceParser.parseSkillDescription(data: Data(fallback.utf8)), "fallback desc")
        XCTAssertNil(MarketplaceParser.parseSkillDescription(data: Data("<html></html>".utf8)))
    }

    // MARK: - 紧凑数字解析

    func testParseCompactCount() {
        XCTAssertEqual(MarketplaceParser.parseCompactCount("129.5K"), 129_500)
        XCTAssertEqual(MarketplaceParser.parseCompactCount("2.1M"), 2_100_000)
        XCTAssertEqual(MarketplaceParser.parseCompactCount("1M"), 1_000_000)
        XCTAssertEqual(MarketplaceParser.parseCompactCount("9906"), 9_906)
        XCTAssertEqual(MarketplaceParser.parseCompactCount("5,147"), 5_147)
        XCTAssertNil(MarketplaceParser.parseCompactCount(""))
        XCTAssertNil(MarketplaceParser.parseCompactCount("abc"))
    }

    // MARK: - 安装量展示文案

    func testInstallsText() {
        func skill(_ installs: Int?) -> MarketplaceSkill {
            MarketplaceSkill(id: "a/b/c", name: "c", description: nil,
                             owner: "a", source: "a/b", installs: installs)
        }
        XCTAssertEqual(skill(172_670).installsText, "172.7K installs")
        XCTAssertEqual(skill(2_100_000).installsText, "2.1M installs")
        XCTAssertEqual(skill(1).installsText, "1 install")
        XCTAssertEqual(skill(9906).installsText, "9.9K installs")
        XCTAssertEqual(skill(nil).installsText, "")
        XCTAssertEqual(skill(0).installsText, "")
    }
}
