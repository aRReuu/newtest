import Foundation

/// A read-only, byte-ranged projection of the common Obsidian Properties subset.
/// Never serialize these values back to a Markdown file: sourceBytes is authoritative.
public enum ImpressFrontmatterFieldKind: String, Sendable {
    case text, date, number, boolean, tags, list, wikilink, empty
}

public struct ImpressFrontmatterField: Sendable, Equatable {
    public let name: String
    public let kind: ImpressFrontmatterFieldKind
    public let values: [String]
    public let rawValue: String
    public let startUTF8: Int
    public let endUTF8: Int

    public var displayValue: String {
        values.isEmpty ? "—" : values.joined(separator: " · ")
    }
}

public enum ImpressFrontmatterState: String, Sendable {
    case absent, valid, unsupported, invalid
}

public struct ImpressFrontmatterReading: Sendable {
    public let state: ImpressFrontmatterState
    public let fields: [ImpressFrontmatterField]
    public let body: String
    public let bodyStartUTF8: Int
    public let diagnostic: String?
}

/// Parses the bounded, safe common scalar/list YAML subset without inferring
/// unknown plugin objects or silently discarding malformed frontmatter.
/// Unhandled YAML constructs are diagnosed and left visible in the source.
public enum ImpressFrontmatterReader {
    private struct Row {
        let start: Int
        let end: Int
        let next: Int
        let text: String
    }

    private static func rows(_ bytes: [UInt8]) -> [Row] {
        var output: [Row] = []
        var offset = 0
        while offset < bytes.count {
            let start = offset
            while offset < bytes.count && bytes[offset] != 10 && bytes[offset] != 13 {
                offset += 1
            }
            let end = offset
            if offset < bytes.count {
                if bytes[offset] == 13 && offset + 1 < bytes.count &&
                    bytes[offset + 1] == 10 {
                    offset += 2
                } else {
                    offset += 1
                }
            }
            output.append(Row(start: start, end: end, next: offset,
                              text: String(decoding: bytes[start..<end], as: UTF8.self)))
        }
        return output
    }

    private static func unsupported(_ source: String, _ message: String)
        -> ImpressFrontmatterReading {
        ImpressFrontmatterReading(state: .unsupported, fields: [], body: source,
                                  bodyStartUTF8: 0, diagnostic: message)
    }

    private static func invalid(_ source: String, _ message: String)
        -> ImpressFrontmatterReading {
        ImpressFrontmatterReading(state: .invalid, fields: [], body: source,
                                  bodyStartUTF8: 0, diagnostic: message)
    }

    private static func splitSequence(_ value: String) -> [String]? {
        guard value.first == "[", value.last == "]" else { return nil }
        let inner = value.dropFirst().dropLast()
        if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        var parts: [String] = []
        var chunk = ""
        var quoted: Character?
        for symbol in inner {
            if symbol == "'" || symbol == "\"" {
                if quoted == nil { quoted = symbol }
                else if quoted == symbol { quoted = nil }
            }
            if symbol == "," && quoted == nil {
                parts.append(chunk.trimmingCharacters(in: .whitespaces))
                chunk = ""
            } else {
                chunk.append(symbol)
            }
        }
        guard quoted == nil else { return nil }
        parts.append(chunk.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func scalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first,
              (first == "\"" || first == "'"), trimmed.last == first else {
            return trimmed
        }
        var result = String(trimmed.dropFirst().dropLast())
        if first == "'" {
            result = result.replacingOccurrences(of: "''", with: "'")
        } else {
            result = result.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
        }
        return result
    }

    private static func kind(_ value: String, key: String) -> ImpressFrontmatterFieldKind {
        if value.isEmpty || value == "null" || value == "~" { return .empty }
        if key.lowercased() == "tags" { return .tags }
        if value.hasPrefix("[[") && value.hasSuffix("]]") { return .wikilink }
        let normalized = value.lowercased()
        if normalized == "true" || normalized == "false" { return .boolean }
        if Double(value)?.isFinite == true { return .number }
        let chars = Array(value)
        if chars.count >= 10, chars[4] == "-", chars[7] == "-",
           chars[0..<4].allSatisfy(\.isNumber),
           chars[5..<7].allSatisfy(\.isNumber),
           chars[8..<10].allSatisfy(\.isNumber),
           (chars.count == 10 || chars[10] == "T" || chars[10] == " ") {
            return .date
        }
        return .text
    }

    public static func parse(_ source: String) -> ImpressFrontmatterReading {
        let bytes = Array(source.utf8)
        let lines = rows(bytes)
        guard let first = lines.first else {
            return ImpressFrontmatterReading(state: .absent, fields: [], body: source,
                                             bodyStartUTF8: 0, diagnostic: nil)
        }
        let opening = first.text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard opening == "---" else {
            return ImpressFrontmatterReading(state: .absent, fields: [], body: source,
                                             bodyStartUTF8: 0, diagnostic: nil)
        }
        guard bytes.count <= 8 * 1024 * 1024 else {
            return unsupported(source, "此笔记超出属性阅读器预算，请查看 Markdown 源码。")
        }
        let upper = min(lines.count, 257)
        guard let closing = (1..<upper).first(where: {
            let trimmed = lines[$0].text.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else {
            return invalid(source, "YAML 属性没有正确的结束分隔线，请查看 Markdown 源码。")
        }
        guard lines[closing].next <= 128 * 1024 else {
            return unsupported(source, "YAML 属性区超过 128 KB，未执行不完整解析。")
        }
        var entries: [ImpressFrontmatterField] = []
        var names = Set<String>()
        var index = 1
        while index < closing {
            let row = lines[index]
            let line = row.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            guard line == String(line.drop(while: { $0 == " " || $0 == "\t" })),
                  let separator = line.firstIndex(of: ":") else {
                return invalid(source, "YAML 属性格式异常，行号：\(index + 1)。源文件未更改。")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let after = line.index(after: separator)
            let raw = String(line[after...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.count <= 160,
                  !name.contains("{"), !name.contains("["),
                  names.insert(name).inserted else {
                return invalid(source, "YAML 属性名为空、重复或超出安全解析范围，行号：\(index + 1)。")
            }
            if raw.hasPrefix("!") || raw.hasPrefix("&") || raw.hasPrefix("*") ||
                raw == "|" || raw == ">" || raw.hasPrefix("{") {
                return unsupported(source, "此文档使用更复杂的 YAML 结构，请使用源码视图核查。")
            }
            let start = row.start
            var end = row.next
            var values: [String] = []
            var fieldKind: ImpressFrontmatterFieldKind = .empty
            if raw.isEmpty || raw == "null" || raw == "~" {
                var follower = index + 1
                while follower < closing {
                    let child = lines[follower].text
                    let indent = child.prefix(while: { $0 == " " }).count
                    let content = child.trimmingCharacters(in: .whitespaces)
                    if content.isEmpty {
                        follower += 1
                        continue
                    }
                    guard indent >= 2 else { break }
                    guard content.hasPrefix("- ") else {
                        return unsupported(source, "属性包含嵌套映射或未知 YAML 序列，需查看源码。")
                    }
                    values.append(scalar(String(content.dropFirst(2))))
                    end = lines[follower].next
                    follower += 1
                }
                if !values.isEmpty {
                    fieldKind = name.lowercased() == "tags" ? .tags : .list
                    index = follower - 1
                }
            } else if raw.hasPrefix("[") && !raw.hasPrefix("[[") {
                guard let seq = splitSequence(raw) else {
                    return invalid(source, "YAML 内联数组格式不完整，行号：\(index + 1)。")
                }
                values = seq.map(scalar)
                fieldKind = name.lowercased() == "tags" ? .tags : .list
            } else {
                let value = scalar(raw)
                if (raw.hasPrefix("\"") && !raw.hasSuffix("\"")) ||
                   (raw.hasPrefix("'") && !raw.hasSuffix("'")) {
                    return invalid(source, "YAML 字符串引号不闭合，行号：\(index + 1)。")
                }
                fieldKind = kind(value, key: name)
                if fieldKind != .empty { values = [value] }
            }
            entries.append(ImpressFrontmatterField(
                name: name, kind: fieldKind, values: values, rawValue: raw,
                startUTF8: start, endUTF8: end))
            index += 1
        }
        let bodyStart = lines[closing].next
        let body = String(decoding: bytes[bodyStart..<bytes.count], as: UTF8.self)
        return ImpressFrontmatterReading(state: .valid, fields: entries,
                                         body: body, bodyStartUTF8: bodyStart,
                                         diagnostic: nil)
    }
}
