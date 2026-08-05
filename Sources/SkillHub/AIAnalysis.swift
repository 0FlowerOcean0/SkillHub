import Foundation

enum AIAnalysisError: LocalizedError {
    case cliNotFound
    case cliFailed(String)
    case parseFailed(String)
    case alreadyAnalyzing

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 claude CLI，请先安装：npm i -g @anthropic-ai/claude-code"
        case .cliFailed(let m): return "CLI 调用失败：\(m)"
        case .parseFailed(let m): return "解析结果失败：\(m)"
        case .alreadyAnalyzing: return "分析正在进行中"
        }
    }
}

struct AIAnalysisResult {
    var tags: [String]
    var summary: String
}

enum AIAnalysis {

    // MARK: - CLI 可用性

    static func findCLI() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "which claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0 && path != nil && !path!.isEmpty) ? path : nil
    }

    // MARK: - 分析单个 skill

    static func analyze(skill: Skill) throws -> AIAnalysisResult {
        guard let cliPath = findCLI() else { throw AIAnalysisError.cliNotFound }

        let md: String
        if let data = try? Data(contentsOf: skill.skillMarkdownPath),
           let text = String(data: data, encoding: .utf8) {
            // 截取前 8000 字符避免 token 爆掉
            md = String(text.prefix(8000))
        } else {
            md = "（无法读取 SKILL.md）"
        }

        let prompt = """
        分析这个 AI skill，用 JSON 格式回复，不要加 markdown 代码块包裹：
        {"tags": ["分类标签1", "分类标签2"], "summary": "一句话中文描述用途"}

        标签从这些类别里选（可多选，也可自定义）：
        writing（写作）, coding（编程）, analysis（分析）, design（设计）,
        devops（运维）, data（数据）, research（调研）, product（产品）,
        marketing（营销）, education（教育）, productivity（效率）, other

        SKILL.md 内容：
        \(md)
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = ["-p", prompt, "--output-format", "json", "--max-turns", "1"]
        let errPipe = Pipe()
        let outPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = outPipe

        try p.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AIAnalysisError.cliFailed(String(err.prefix(300)))
        }

        return try parseCLIOutput(data)
    }

    // MARK: - 批量分析

    static func analyzeBatch(
        skills: [Skill],
        progress: @escaping (Int, Int, Skill) -> Void
    ) async throws -> [String: AIAnalysisResult] {
        var results: [String: AIAnalysisResult] = [:]
        let total = skills.count
        for (i, skill) in skills.enumerated() {
            await MainActor.run { progress(i + 1, total, skill) }
            do {
                let result = try analyze(skill: skill)
                results[skill.id] = result
            } catch {
                // 单个失败不中断批量
                print("分析 \(skill.name) 失败：\(error.localizedDescription)")
            }
        }
        return results
    }

    // MARK: - 写回 frontmatter

    static func writeResults(_ results: [String: AIAnalysisResult], to skills: [Skill]) {
        for skill in skills {
            guard let result = results[skill.id] else { continue }
            writeSingle(result: result, to: skill.skillMarkdownPath)
        }
    }

    static func writeSingle(result: AIAnalysisResult, to fileURL: URL) {
        guard var text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        // 检查有没有 frontmatter
        let hasFM = text.hasPrefix("---")
        let tagsLine = "tags: [\(result.tags.map { "\"\($0)\"" }.joined(separator: ", "))]"
        let summaryLine = "summary: \"\(result.summary.replacingOccurrences(of: "\"", with: "\\\""))\""

        if hasFM {
            // 在第二个 --- 之前插入/替换 tags 和 summary
            if let endRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 1)..<text.endIndex) {
                let body = String(text[endRange.upperBound...])
                var header = String(text[..<endRange.lowerBound])

                // 替换或添加 tags
                header = replaceOrInsert(key: "tags", line: tagsLine, in: header)
                // 替换或添加 summary
                header = replaceOrInsert(key: "summary", line: summaryLine, in: header)

                text = header + "\n---" + body
            }
        } else {
            // 没有 frontmatter，新建
            text = "---\n\(tagsLine)\n\(summaryLine)\n---\n\(text)"
        }

        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func replaceOrInsert(key: String, line: String, in header: String) -> String {
        var lines = header.components(separatedBy: .newlines)
        if let idx = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[idx] = line
        } else {
            // 找到 --- 前一行插入
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 解析 CLI JSON 输出

    private static func parseCLIOutput(_ data: Data) throws -> AIAnalysisResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAnalysisError.parseFailed("无法解析 JSON")
        }

        guard let resultStr = json["result"] as? String else {
            throw AIAnalysisError.parseFailed("缺少 result 字段")
        }

        // result 可能被 ```json ``` 包裹
        var cleaned = resultStr
        if cleaned.contains("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let resultData = cleaned.data(using: .utf8),
              let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw AIAnalysisError.parseFailed("无法解析 result 内容：\(cleaned.prefix(200))")
        }

        let tags = (resultJSON["tags"] as? [String]) ?? []
        let summary = (resultJSON["summary"] as? String) ?? ""

        return AIAnalysisResult(tags: tags, summary: summary)
    }
}
