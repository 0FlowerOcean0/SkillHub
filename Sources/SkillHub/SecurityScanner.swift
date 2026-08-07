import Foundation

/// 安全扫描发现：一条规则在一个文件某一行上的命中
struct SecurityFinding: Hashable, Codable {

    enum Severity: String, Comparable, CaseIterable, Codable {
        case high, medium, low

        private var rank: Int {
            switch self {
            case .high: return 0
            case .medium: return 1
            case .low: return 2
            }
        }
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }

        /// 评分扣分权重
        var penalty: Int {
            switch self {
            case .high: return 20
            case .medium: return 10
            case .low: return 3
            }
        }

        var displayName: String {
            switch self {
            case .high: return "高危"
            case .medium: return "中危"
            case .low: return "低危"
            }
        }
    }

    let ruleID: String
    let severity: Severity
    /// 相对 skill 根目录的路径
    let file: String
    /// 行号（1 起），未能定位时为 nil
    let line: Int?
    /// 命中行摘要（截断到 80 字符）
    let snippet: String
    /// 说明文案
    let message: String
}

/// 一个 skill 的安全扫描报告
struct SecurityReport {
    let findings: [SecurityFinding]
    /// 0-100，按严重度扣分
    let score: Int

    enum Grade: String {
        case safe = "安全"
        case caution = "注意"
        case risky = "风险"
    }

    var grade: Grade {
        if score >= 90 { return .safe }
        if score >= 60 { return .caution }
        return .risky
    }

    var highCount: Int { findings.filter { $0.severity == .high }.count }
    var mediumCount: Int { findings.filter { $0.severity == .medium }.count }
    var lowCount: Int { findings.filter { $0.severity == .low }.count }
}

/// 扫描规则：表驱动，新增规则往 SecurityScanner.rules 里加一条即可
struct SecurityRule {
    let id: String
    let severity: SecurityFinding.Severity
    /// NSRegularExpression 模式（按行匹配，大小写不敏感）
    let pattern: String
    /// 说明文案
    let message: String
    /// 命中行包含这些子串之一则不报（用于知名域名白名单等降噪）
    var allowlist: [String] = []
    /// 同一行已命中这些规则时，本规则的命中被抑制（避免强弱规则双报）
    var suppressedBy: [String] = []

    var regex: NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

enum SecurityScanner {

    /// 超过该大小的文件跳过（1 MB）
    static let maxScannableBytes = 1_024 * 1_024

    /// 只扫描这些扩展名的文本文件
    static let scannableExtensions: Set<String> = [
        "md", "markdown", "txt",
        "sh", "bash", "zsh", "fish", "ps1",
        "py", "rb", "pl",
        "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "json", "yaml", "yml", "toml",
    ]

    /// 命中行摘要的最大长度
    static let snippetMaxLength = 80

    // MARK: - 规则集（表驱动）

    static let rules: [SecurityRule] = [
        // —— 危险删除 ——
        SecurityRule(
            id: "rm-rf-root",
            severity: .high,
            pattern: #"\brm\s+-[a-z0-9]*[rf][a-z0-9]*\s+(?:--\S+\s+)*(?:~|\$\{?HOME\}?|/(?:\*|\s|$))"#,
            message: "危险删除：rm -rf 指向用户目录或系统根目录"
        ),
        SecurityRule(
            id: "rm-rf",
            severity: .medium,
            pattern: #"\brm\s+-[a-z0-9]*[rf][a-z0-9]*(\s|$)"#,
            message: "强制递归删除：rm -rf，需确认目标路径安全",
            suppressedBy: ["rm-rf-root"]
        ),
        SecurityRule(
            id: "win-del-force",
            severity: .high,
            pattern: #"\bdel\s+/[fq]"#,
            message: "危险删除：Windows del /f 强制删除"
        ),
        SecurityRule(
            id: "win-format",
            severity: .high,
            pattern: #"\bformat\s+[a-z]:"#,
            message: "危险操作：格式化磁盘分区"
        ),

        // —— 远程执行 ——
        SecurityRule(
            id: "pipe-remote-exec",
            severity: .high,
            pattern: #"\b(?:curl|wget)\b[^\n]*\|\s*(?:sudo\s+)?(?:bash|sh|zsh|python[0-9]*)(?:\s|$)"#,
            message: "远程执行：下载后直接管道给 shell 执行"
        ),
        SecurityRule(
            id: "eval-exec",
            severity: .high,
            pattern: #"\beval\s*\("#,
            message: "动态执行：eval() 可执行任意代码"
        ),
        SecurityRule(
            id: "base64-exec",
            severity: .high,
            pattern: #"\bbase64\s+(?:-[a-z]*d|--decode)[^\n]*(?:\|\s*(?:bash|sh|zsh|python[0-9]*)|eval)"#,
            message: "隐蔽执行：base64 解码后交给 shell 执行"
        ),

        // —— 凭据 / 敏感访问 ——
        SecurityRule(
            id: "ssh-key-access",
            severity: .high,
            pattern: #"\.ssh/"#,
            message: "敏感访问：读取 ~/.ssh 下的私钥或配置"
        ),
        SecurityRule(
            id: "aws-credentials",
            severity: .high,
            pattern: #"\.aws/credentials"#,
            message: "敏感访问：读取 AWS 凭据文件"
        ),
        SecurityRule(
            id: "keychain-access",
            severity: .high,
            pattern: #"\bsecurity\s+(?:find|dump)|SecItemCopyMatching"#,
            message: "敏感访问：读取 macOS 钥匙串"
        ),
        SecurityRule(
            id: "secret-exfil",
            severity: .medium,
            pattern: #"(?:API_KEY|SECRET|TOKEN|PASSWORD)[^\n]{0,80}(?:curl|requests\.|fetch\(|urllib)|(?:curl|requests\.|fetch\(|urllib)[^\n]{0,80}(?:API_KEY|SECRET|TOKEN|PASSWORD)"#,
            message: "疑似外发：读取密钥/令牌环境变量并伴随网络请求"
        ),

        // —— 网络外发（误报多，低危）——
        SecurityRule(
            id: "net-post",
            severity: .low,
            pattern: #"\bcurl\b[^\n]*-X\s*POST|\brequests\.post\s*\(|\bfetch\s*\([^\n]*method"#,
            message: "网络外发：向外部发起 POST 请求",
            allowlist: [
                "github.com", "apple.com", "openai.com", "anthropic.com",
                "googleapis.com", "npmjs.com", "pypi.org", "microsoft.com",
                "cloudflare.com",
            ]
        ),

        // —— 权限提升 ——
        SecurityRule(
            id: "sudo",
            severity: .low,
            pattern: #"\bsudo\s+"#,
            message: "权限提升：使用 sudo 执行命令"
        ),
        SecurityRule(
            id: "chmod-777",
            severity: .medium,
            pattern: #"\bchmod\s+(?:-[a-zA-Z]+\s+)*777"#,
            message: "权限过宽：chmod 777 将文件开放给所有用户读写执行"
        ),
    ]

    // MARK: - 扫描入口

    static func scan(skill: Skill) -> SecurityReport {
        scan(directory: skill.canonicalPath)
    }

    /// 扫描目录下所有可扫描文本文件，返回报告
    static func scan(directory root: URL) -> SecurityReport {
        let fm = FileManager.default
        var findings: [SecurityFinding] = []

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return SecurityReport(findings: [], score: 100)
        }

        for case let url as URL in enumerator {
            // 明确跳过 .git（双保险，.skipsHiddenFiles 通常已覆盖）
            if url.pathComponents.contains(".git") {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }
            // 跳过超大文件
            if let size = values.fileSize, size > maxScannableBytes { continue }
            // 只扫描白名单扩展名
            guard scannableExtensions.contains(url.pathExtension.lowercased()) else { continue }

            let relPath = relativePath(of: url, under: root)
            findings.append(contentsOf: scanFile(url, relativePath: relPath))
        }

        findings = suppressRedundant(findings)
        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
            if lhs.file != rhs.file { return lhs.file < rhs.file }
            return (lhs.line ?? 0) < (rhs.line ?? 0)
        }

        let score = max(0, 100 - findings.reduce(0) { $0 + $1.severity.penalty })
        return SecurityReport(findings: findings, score: score)
    }

    // MARK: - 单文件扫描

    static func scanFile(_ url: URL, relativePath: String) -> [SecurityFinding] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        // 跳过二进制（前 8KB 内出现 NUL 视为二进制）
        let head = data.prefix(8_192)
        if head.contains(0) { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var findings: [SecurityFinding] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            for rule in rules {
                guard let regex = rule.regex else { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }
                if rule.allowlist.contains(where: { line.localizedCaseInsensitiveContains($0) }) { continue }
                findings.append(SecurityFinding(
                    ruleID: rule.id,
                    severity: rule.severity,
                    file: relativePath,
                    line: index + 1,
                    snippet: makeSnippet(line),
                    message: rule.message
                ))
            }
        }
        return findings
    }

    // MARK: - 工具

    /// 截断到 80 字符，超出加省略号
    static func makeSnippet(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > snippetMaxLength else { return trimmed }
        return String(trimmed.prefix(snippetMaxLength)) + "…"
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(rootPath) {
            var rel = String(fullPath.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }

    /// 同一行同时命中强弱规则时，只保留强规则
    static func suppressRedundant(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        let ruleByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        return findings.filter { finding in
            guard let suppressedBy = ruleByID[finding.ruleID]?.suppressedBy, !suppressedBy.isEmpty else { return true }
            return !findings.contains { other in
                other.file == finding.file && other.line == finding.line && suppressedBy.contains(other.ruleID)
            }
        }
    }
}
