import Foundation

/// 轻量 YAML frontmatter 解析器。
/// 只针对 SKILL.md 的实际形态：顶层 key: value、`>` / `|` / `>-` / `|-` 折叠块、
/// 二级缩进的 metadata 子字段。不追求完整 YAML 规范。
enum FrontmatterParser {

    struct Result {
        var fields: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var hasFrontmatter = false
        var name: String? { fields["name"] }
        var descriptionText: String? { fields["description"] }
        var version: String? { fields["version"] ?? fields["metadata.version"] }
        var tags: [String] { arrays["tags"] ?? [] }
        var summary: String? { fields["summary"] }
        var author: String? { fields["author"] ?? fields["metadata.author"] }
    }

    static func parse(markdown: String) -> Result {
        var result = Result()
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }

        var i = 1
        var currentKey: String? = nil      // 正在收集折叠块的 key
        var blockLines: [String] = []
        var blockIndent: Int? = nil
        var parentKey: String? = nil       // 如 metadata
        var arrayKey: String? = nil        // 正在收集的 YAML 数组 key
        var arrayItems: [String] = []

        func flushBlock() {
            if let key = currentKey {
                result.fields[key] = blockLines.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentKey = nil
            blockLines = []
            blockIndent = nil
        }

        func flushArray() {
            if let key = arrayKey, !arrayItems.isEmpty {
                result.arrays[key] = arrayItems
            }
            arrayKey = nil
            arrayItems = []
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " }).count

            // 折叠块收集中（优先于 --- 结束判断：块内缩进的 --- 属于内容）
            if currentKey != nil {
                if trimmed.isEmpty { i += 1; continue }
                if indent >= (blockIndent ?? 2) {
                    blockLines.append(trimmed)
                    i += 1
                    continue
                }
                flushBlock()
            }

            // 顶格的 --- 才是 frontmatter 结束标记
            if trimmed == "---" && indent == 0 {
                flushArray()
                result.hasFrontmatter = true
                return result
            }

            // YAML 数组收集中
            if arrayKey != nil {
                if trimmed.hasPrefix("- ") {
                    let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    arrayItems.append(item)
                    i += 1
                    continue
                } else if trimmed.isEmpty {
                    i += 1
                    continue
                } else {
                    flushArray()
                }
            }

            if trimmed.isEmpty { i += 1; continue }

            // 解析 key: value
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

                if indent == 0 { parentKey = nil }
                let fullKey: String
                if indent > 0, let p = parentKey {
                    fullKey = "\(p).\(key)"
                } else {
                    fullKey = key
                }

                if value.isEmpty {
                    // 检查下一行是否是数组
                    if i + 1 < lines.count {
                        let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        if nextTrimmed.hasPrefix("- ") {
                            arrayKey = fullKey
                            arrayItems = []
                            i += 1
                            continue
                        }
                    }
                    if indent == 0 { parentKey = key }
                    i += 1
                    continue
                }

                // 行内数组 [a, b, c]
                if value.hasPrefix("["), value.hasSuffix("]") {
                    let inner = String(value.dropFirst().dropLast())
                    result.arrays[fullKey] = inner.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    }
                    i += 1
                    continue
                }

                if value == ">" || value == "|" || value == ">-" || value == "|-" || value == ">+" || value == "|+" {
                    currentKey = fullKey
                    blockIndent = indent + 1
                    blockLines = []
                    i += 1
                    continue
                }
                // 去掉包裹引号
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                result.fields[fullKey] = value
            }
            i += 1
        }
        flushBlock()
        flushArray()
        return result
    }

    static func parse(fileURL: URL) -> Result {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Result() }
        return parse(markdown: text)
    }
}
