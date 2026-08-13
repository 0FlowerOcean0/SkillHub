import Foundation

// MARK: - 技能市场：数据模型 + 网络/解析服务
//
// skills.sh 接口探测结论（2025 年实测，curl 验证）：
//
// 1. 搜索 JSON API（与 `npx skills find <query>` 同源，见 vercel-labs/skills 仓库 src/find.ts）：
//      GET https://skills.sh/api/search?q=<query>&limit=20
//    响应示例：
//      {"query":"pdf","searchType":"fuzzy","skills":[
//        {"id":"anthropics/skills/pdf","skillId":"pdf","name":"pdf","installs":172670,"source":"anthropics/skills"},
//        ...
//      ]}
//    - query 少于 2 个字符时返回 {"error":"Query must be at least 2 characters"}
//    - CLI 里 SEARCH_API_BASE 可被 SKILLS_API_URL 环境变量覆盖，本模块同样保留 baseURL 可注入。
//
// 2. 热门榜单：没有独立的 JSON API（/api/trending、/api/leaderboard、/api/popular 均为 404/HTML），
//    首页 https://skills.sh 是服务端渲染 HTML，内嵌 leaderboard。条目结构：
//      <a ... href="/anthropics/skills/webapp-testing">
//        <span class="text-sm lg:text-base text-(--ds-gray-600) font-mono">222</span>   <- 排名
//        <h3 class="font-semibold text-foreground truncate whitespace-nowrap">webapp-testing</h3>
//        <p class="...">anthropics/skills</p>                                            <- owner/repo
//        <span class="font-mono text-sm text-foreground">129.5K</span>                   <- 安装量（紧凑格式）
//      </a>
//    解析时要求条目内包含 <h3>，以排除导航/页脚里同形状（/x/y/z 三段路径）的链接。
//
// 3. 技能描述：搜索 API 不含描述；详情页 https://skills.sh/<owner>/<repo>/<skillId>
//    的 <meta property="og:description" content="..."> 里有，按需逐条补取并缓存。
//
// 4. 退路（本模块未启用，仅记录）：若 skills.sh 接口变动，可改用 GitHub Search API
//    （https://api.github.com/search/repositories?q=...，无鉴权但有速率限制）搜索含 SKILL.md 的仓库。

// MARK: - 模型

/// 技能市场里的一条技能
struct MarketplaceSkill: Identifiable, Hashable {
    /// 完整标识："owner/repo/skillId"，如 "anthropics/skills/webapp-testing"
    let id: String
    /// 展示名，如 "webapp-testing"
    let name: String
    /// 描述（搜索接口不提供，由详情页补取；可能为空）
    var description: String?
    /// 作者 / owner，如 "anthropics"
    let owner: String
    /// 仓库源标识："owner/repo"，如 "anthropics/skills"——安装时传给安装闭包
    let source: String
    /// 安装量（未知则为 nil）
    let installs: Int?

    /// 仓库内的 skill 标识。市场 id 固定为 owner/repo/skillId。
    var skillID: String { id.split(separator: "/").last.map(String.init) ?? name }

    /// skills.sh 详情页
    var skillPageURL: URL { URL(string: "https://skills.sh/\(id)")! }
    /// GitHub 仓库页
    var repoURL: URL { URL(string: "https://github.com/\(source)")! }

    /// 安装量的紧凑展示，如 "129.5K installs"（与 skills CLI 的格式一致）
    var installsText: String {
        guard let installs, installs > 0 else { return "" }
        if installs >= 1_000_000 {
            return "\(trimmed(String(format: "%.1f", Double(installs) / 1_000_000)))M installs"
        }
        if installs >= 1_000 {
            return "\(trimmed(String(format: "%.1f", Double(installs) / 1_000)))K installs"
        }
        return "\(installs) install\(installs == 1 ? "" : "s")"
    }

    private func trimmed(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

// MARK: - 错误

enum MarketplaceError: LocalizedError {
    case invalidQuery            // 搜索词太短
    case network(String)         // 网络层失败（超时、断网等）
    case httpStatus(Int)         // 非 2xx
    case server(String)          // 服务端业务错误（{"error": "..."}）
    case decoding                // 响应不是预期 JSON

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "搜索词至少需要 2 个字符"
        case .network(let m): return "网络请求失败：\(m)"
        case .httpStatus(let c): return "服务器返回错误（HTTP \(c)）"
        case .server(let m): return m
        case .decoding: return "响应数据格式无法识别"
        }
    }
}

// MARK: - 解析层（纯函数：Data -> 模型，便于单测，不涉及网络）

enum MarketplaceParser {

    private struct SearchResponseDTO: Decodable {
        struct SkillDTO: Decodable {
            let id: String?
            let skillId: String?
            let name: String?
            let installs: Int?
            let source: String?
        }
        let skills: [SkillDTO]?
        let error: String?
    }

    /// 解析 /api/search 的 JSON 响应；缺字段容错（installs 可缺，缺 id/source 的条目跳过）
    static func parseSearchResults(data: Data) throws -> [MarketplaceSkill] {
        let dto: SearchResponseDTO
        do {
            dto = try JSONDecoder().decode(SearchResponseDTO.self, from: data)
        } catch {
            throw MarketplaceError.decoding
        }
        if let error = dto.error { throw MarketplaceError.server(error) }
        return (dto.skills ?? []).compactMap { s in
            guard let id = s.id, !id.isEmpty,
                  let source = s.source, !source.isEmpty,
                  let name = (s.name?.isEmpty == false ? s.name : s.skillId), !name.isEmpty
            else { return nil }
            let owner = source.split(separator: "/").first.map(String.init) ?? ""
            return MarketplaceSkill(id: id, name: name, description: nil,
                                    owner: owner, source: source, installs: s.installs)
        }
    }

    /// 解析 skills.sh 首页内嵌的 leaderboard HTML
    static func parseLeaderboard(data: Data) -> [MarketplaceSkill] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        var results: [MarketplaceSkill] = []
        var seen = Set<String>()

        // 条目：<a ... href="/owner/repo/skillId"> ... </a>，内部必须含 <h3>（排除导航链接）
        let entryPattern = #"<a\b[^>]*href="(/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)"[^>]*>(.*?)</a>"#
        guard let entryRe = try? NSRegularExpression(pattern: entryPattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)

        for m in entryRe.matches(in: html, range: range) {
            guard let idRange = Range(m.range(at: 1), in: html),
                  let bodyRange = Range(m.range(at: 2), in: html) else { continue }
            let body = String(html[bodyRange])
            guard body.contains("<h3") else { continue }

            let id = String(html[idRange]).dropFirst() // 去掉前导 "/"
            guard seen.insert(String(id)).inserted else { continue }

            let segments = id.split(separator: "/").map(String.init)
            guard segments.count == 3 else { continue }
            let source = "\(segments[0])/\(segments[1])"

            guard let rawName = firstCapture(#"<h3\b[^>]*>([^<]+)</h3>"#, in: body) else { continue }
            let name = decodingHTMLEntities(rawName)
            let installs = firstCapture(#"<span\b[^>]*class="[^"]*font-mono text-sm text-foreground[^"]*"[^>]*>([^<]+)</span>"#, in: body)
                .flatMap { parseCompactCount($0) }

            results.append(MarketplaceSkill(id: String(id), name: name, description: nil,
                                            owner: segments[0], source: source, installs: installs))
        }
        return results
    }

    /// 从详情页 HTML 提取 og:description（兼容 name="description" 兜底）
    static func parseSkillDescription(data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [
            #"<meta\b[^>]*property="og:description"[^>]*content="([^"]*)""#,
            #"<meta\b[^>]*content="([^"]*)"[^>]*property="og:description""#,
            #"<meta\b[^>]*name="description"[^>]*content="([^"]*)""#,
        ]
        for p in patterns {
            if let raw = firstCapture(p, in: html) {
                let text = decodingHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// 紧凑数字解析："129.5K" -> 129500，"2.1M" -> 2100000，"9906" -> 9906
    static func parseCompactCount(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .uppercased()
        guard !t.isEmpty else { return nil }
        if t.hasSuffix("K"), let v = Double(t.dropLast()) { return Int(v * 1_000) }
        if t.hasSuffix("M"), let v = Double(t.dropLast()) { return Int(v * 1_000_000) }
        return Int(t)
    }

    /// 最小化的 HTML 实体反转义（&amp; 必须最后处理，避免二次反转义）
    static func decodingHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - 网络层（只做请求，把 Data 交给解析层）

struct MarketplaceService {
    let baseURL: URL
    let session: URLSession
    let timeout: TimeInterval

    init(baseURL: URL = URL(string: "https://skills.sh")!,
         session: URLSession = .shared,
         timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    /// 搜索技能（对应 `npx skills find <query>`）
    func search(query: String, limit: Int = 20) async throws -> [MarketplaceSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw MarketplaceError.invalidQuery }
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/search"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let data = try await get(comps.url!)
        return try MarketplaceParser.parseSearchResults(data: data)
    }

    /// 热门榜单（首页 leaderboard）
    func fetchPopular() async throws -> [MarketplaceSkill] {
        let data = try await get(baseURL)
        return MarketplaceParser.parseLeaderboard(data: data)
    }

    /// 按需补取单个技能的描述（详情页 og:description）；失败静默返回 nil
    func fetchDescription(for skill: MarketplaceSkill) async -> String? {
        guard let data = try? await get(baseURL.appendingPathComponent(skill.id)) else { return nil }
        return MarketplaceParser.parseSkillDescription(data: data)
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        req.setValue("SkillHub/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw MarketplaceError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw MarketplaceError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketplaceError.httpStatus(http.statusCode)
        }
        return data
    }
}
