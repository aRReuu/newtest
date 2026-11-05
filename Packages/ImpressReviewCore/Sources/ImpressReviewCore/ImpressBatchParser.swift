import Foundation

/// Pure Foundation, deterministic R04.2-C import parser. No network, UI or storage.
public enum ImpressBatchFormat: String, Sendable {
    case text, csv, tsv, markdown
}

public struct ImpressBatchParsedRow: Sendable, Equatable {
    public let line: Int
    public let raw: String
    public var question: String
    public var answer: String
    public var choices: [String]
    /// Zero-based indices, only when explicitly supplied in source material.
    public var correctIndices: [Int]
    public var issues: [String]

    public var isChoice: Bool { !choices.isEmpty }
    public var isValid: Bool { issues.isEmpty }

    public init(line: Int, raw: String, question: String = "", answer: String = "",
                choices: [String] = [], correctIndices: [Int] = [],
                issues: [String] = []) {
        self.line = line
        self.raw = raw
        self.question = question
        self.answer = answer
        self.choices = choices
        self.correctIndices = correctIndices
        self.issues = issues
    }
}

public enum ImpressBatchParser {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumRecords = 500

    public static func parse(_ text: String, as format: ImpressBatchFormat) -> [ImpressBatchParsedRow] {
        guard !text.isEmpty else { return [] }
        guard text.utf8.count <= maximumBytes else {
            return [ImpressBatchParsedRow(line: 1, raw: "", issues: ["文件超过 2MB 解析上限。"])]
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows: [ImpressBatchParsedRow]
        switch format {
        case .text, .markdown:
            rows = parseLabeled(normalized)
        case .csv, .tsv:
            rows = parseDelimited(normalized, separator: format == .csv ? "," : "\t")
        }
        guard rows.count <= maximumRecords else {
            return [ImpressBatchParsedRow(line: 1, raw: "", issues: ["最多预览 500 条记录，请分批导入。"])]
        }
        return rows
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func labeled(_ line: String) -> (kind: String, value: String)? {
        var s = clean(line)
        while s.hasPrefix("#") { s.removeFirst(); s = clean(s) }
        if s.hasPrefix("- ") { s = clean(String(s.dropFirst(2))) }
        if s.hasPrefix("**") { s = String(s.dropFirst(2)) }
        let prefixes: [(String, String)] = [
            ("Question:", "q"), ("Answer:", "a"), ("Q:", "q"), ("A:", "a"),
            ("Question：", "q"), ("Answer：", "a"), ("Q：", "q"), ("A：", "a"),
            ("问题：", "q"), ("答案：", "a"), ("问题:", "q"), ("答案:", "a")
        ]
        for (prefix, kind) in prefixes where s.lowercased().hasPrefix(prefix.lowercased()) {
            var value = clean(String(s.dropFirst(prefix.count)))
            if value.hasPrefix("**") { value = clean(String(value.dropFirst(2))) }
            return (kind, value)
        }
        return nil
    }

    private static func parseLabeled(_ text: String) -> [ImpressBatchParsedRow] {
        let lines = text.components(separatedBy: "\n")
        var result: [ImpressBatchParsedRow] = []
        var start = 1
        var original: [String] = []
        var question: [String] = []
        var answer: [String] = []
        var active: String? = nil

        func flush() {
            guard original.contains(where: { !clean($0).isEmpty }) else {
                original.removeAll(); question.removeAll(); answer.removeAll()
                active = nil; return
            }
            let q = clean(question.joined(separator: "\n"))
            let a = clean(answer.joined(separator: "\n"))
            var issues: [String] = []
            if q.isEmpty { issues.append("缺少明确的 Q:/问题：字段。") }
            if a.isEmpty { issues.append("缺少明确的 A:/答案：字段，不会推测正确答案。") }
            result.append(ImpressBatchParsedRow(line: start,
                raw: original.joined(separator: "\n"), question: q,
                answer: a, issues: issues))
            original.removeAll(); question.removeAll(); answer.removeAll()
            active = nil
        }
        for (offset, line) in lines.enumerated() {
            let tag = labeled(line)
            if tag?.kind == "q" && original.contains(where: { !clean($0).isEmpty }) {
                flush()
            } else if clean(line).isEmpty && active == "a" {
                flush()
                continue
            }
            if original.isEmpty { start = offset + 1 }
            original.append(line)
            if let tag {
                active = tag.kind
                if active == "q" { question.append(tag.value) } else { answer.append(tag.value) }
            } else if !clean(line).isEmpty {
                if active == "q" { question.append(line) }
                else if active == "a" { answer.append(line) }
            }
        }
        flush()
        return result
    }

    private struct DelimitedRecord {
        var cells: [String]
        var raw: String
        var line: Int
        var malformed: Bool
    }

    /// RFC4180-style quoted cells, "" escaping and embedded line breaks.
    /// Invalid quoting is retained as a diagnostic, not silently repaired.
    private static func readDelimited(_ text: String, separator: Character) -> [DelimitedRecord] {
        let characters = Array(text)
        var records: [DelimitedRecord] = []
        var fields: [String] = []
        var field = ""
        var raw = ""
        var quoted = false
        var quoteClosed = false
        var malformed = false
        var line = 1
        var startLine = 1
        var i = 0
        func finish() {
            fields.append(field)
            if !fields.allSatisfy({ clean($0).isEmpty }) || malformed {
                records.append(DelimitedRecord(cells: fields, raw: raw,
                                               line: startLine, malformed: malformed || quoted))
            }
            fields.removeAll()
            field = ""
            raw = ""
            malformed = false
            quoted = false
            quoteClosed = false
            startLine = line
        }
        while i < characters.count {
            let ch = characters[i]
            raw.append(ch)
            if ch == "\"" {
                if quoted && i + 1 < characters.count && characters[i + 1] == "\"" {
                    field.append("\"")
                    raw.append("\"")
                    i += 1
                } else if quoted {
                    quoted = false
                    quoteClosed = true
                } else if field.isEmpty && !quoteClosed {
                    quoted = true
                } else {
                    malformed = true
                    field.append(ch)
                }
            } else if ch == separator && !quoted {
                fields.append(field)
                field = ""
                quoteClosed = false
            } else if ch == "\n" && !quoted {
                line += 1
                finish()
            } else {
                if quoteClosed && ch != " " && ch != "\t" { malformed = true }
                field.append(ch)
                if ch == "\n" { line += 1 }
            }
            i += 1
        }
        if !raw.isEmpty || !fields.isEmpty || !field.isEmpty { finish() }
        return records
    }

    private static func parseDelimited(_ text: String, separator: Character) -> [ImpressBatchParsedRow] {
        let all = readDelimited(text, separator: separator)
        guard let header = all.first else { return [] }
        func key(_ s: String) -> String {
            clean(s).lowercased().replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
        }
        let columns = header.cells.map(key)
        func index(_ alternatives: [String]) -> Int? {
            columns.firstIndex(where: { alternatives.contains($0) })
        }
        let qIndex = index(["question", "front", "q", "问题", "题目"])
        let aIndex = index(["answer", "back", "a", "答案"])
        let typeIndex = index(["type", "题型"])
        let optionIndex = index(["choices", "options", "选项"])
        let correctIndex = index(["correct", "correctindices", "正确答案", "正确选项"])
        return all.dropFirst().map { record in
            func cell(_ index: Int?) -> String {
                guard let index, record.cells.indices.contains(index) else { return "" }
                return clean(record.cells[index])
            }
            let question = cell(qIndex)
            let answer = cell(aIndex)
            let rawType = cell(typeIndex).lowercased()
            let optionValue = cell(optionIndex)
            let isChoice = ["choice", "multiplechoice", "选择题", "single", "multiple"].contains(rawType)
                || !optionValue.isEmpty
            let choices = isChoice
                ? optionValue.components(separatedBy: "|").map(clean)
                : []
            let correctField = cell(correctIndex)
            var correct: [Int] = []
            var issues: [String] = []
            if record.malformed { issues.append("CSV/TSV 引号转义不正确。") }
            if record.cells.count != columns.count { issues.append("列数与表头不一致。") }
            if qIndex == nil || question.isEmpty { issues.append("缺少 question/问题 列或内容。") }
            if !rawType.isEmpty && !["qa", "text", "question", "问答", "choice", "multiplechoice",
                "选择题", "single", "multiple"].contains(rawType) {
                issues.append("未知卡片类型。")
            }
            if isChoice {
                if !(2...12).contains(choices.count) || choices.contains(where: { $0.isEmpty }) {
                    issues.append("选择题需要 2–12 个有效选项，以 | 分隔。")
                }
                if correctField.isEmpty {
                    issues.append("选择题缺少正确答案，不会猜测。")
                } else {
                    for token in correctField.split(separator: ",", omittingEmptySubsequences: false) {
                        let trimmed = clean(String(token))
                        guard let number = Int(trimmed), number > 0,
                              number <= choices.count else {
                            issues.append("正确答案索引必须是从 1 开始的有效选项序号。")
                            continue
                        }
                        correct.append(number - 1)
                    }
                    if Set(correct).count != correct.count {
                        issues.append("正确答案索引重复。")
                    }
                }
            } else if answer.isEmpty {
                issues.append("缺少答案，不会猜测。")
            }
            return ImpressBatchParsedRow(line: record.line, raw: record.raw,
                question: question, answer: answer, choices: choices,
                correctIndices: correct, issues: issues)
        }
    }
}


/// Backwards-compatible Vault + complete relative-path authority carried in
/// the existing source_note_path column. No WCDB 1.1.0 migration is needed.
public enum ImpressBatchSourceKey {
    private static let legacyPrefix = "obsidian+v1:"
    private static let versionedPrefix = "obsidian+v2:"
    /// Exact one-section anchors are opt-in. v1/v2 links remain readable and
    /// intentionally have no trustworthy fine-grained locator.
    private static let anchoredPrefix = "obsidian+v3:"

    private static func payload(for identity: ImVaultFileIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func verifiedDigest(_ digest: String) throws -> String {
        guard digest.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
        else { throw ImVaultCoreError.invalidVaultIdentity }
        return digest.lowercased()
    }

    /// Existing cards keep the v1 encoding; newly imported note-backed cards
    /// also retain the exact SHA-256 digest observed when questions were made.
    /// Both encodings live in the existing source_note_path column.
    public static func encode(_ identity: ImVaultFileIdentity,
                              documentDigest: String? = nil,
                              anchoredSection: String? = nil) throws -> String {
        let value = try payload(for: identity)
        guard let documentDigest else {
            guard anchoredSection == nil else { throw ImVaultCoreError.invalidDraft }
            return legacyPrefix + value
        }
        let digest = try verifiedDigest(documentDigest)
        guard let anchoredSection else { return versionedPrefix + value + ":" + digest }
        // Empty or implausibly large sections are not precise evidence.
        guard !anchoredSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              anchoredSection.utf8.count <= 80_000 else {
            throw ImVaultCoreError.invalidDraft
        }
        return anchoredPrefix + value + ":" + digest + ":" +
            ImVaultDigest.sha256(Data(anchoredSection.utf8))
    }

    /// Allows one scoped SQL prefix search for v2 links; callers MUST decode
    /// and compare complete file identities before presenting a match.
    public static func versionedPrefix(for identity: ImVaultFileIdentity) throws -> String {
        versionedPrefix + (try payload(for: identity)) + ":"
    }

    private static func components(_ value: String)
        throws -> (payload: String, documentDigest: String?, sectionDigest: String?)? {
        if value.hasPrefix(legacyPrefix) {
            return (String(value.dropFirst(legacyPrefix.count)), nil, nil)
        }
        if value.hasPrefix(versionedPrefix) {
            let items = value.dropFirst(versionedPrefix.count)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard items.count == 2 else { throw ImVaultCoreError.invalidVaultIdentity }
            return (String(items[0]), try verifiedDigest(String(items[1])), nil)
        }
        if value.hasPrefix(anchoredPrefix) {
            let items = value.dropFirst(anchoredPrefix.count)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard items.count == 3 else { throw ImVaultCoreError.invalidVaultIdentity }
            return (String(items[0]), try verifiedDigest(String(items[1])),
                    try verifiedDigest(String(items[2])))
        }
        return nil // Legacy unverified plain paths have no stable Vault ID.
    }

    public static func decode(_ value: String) throws -> ImVaultFileIdentity? {
        guard let payload = try components(value)?.payload else { return nil }
        let raw = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let identity = try? JSONDecoder().decode(ImVaultFileIdentity.self, from: data)
        else { throw ImVaultCoreError.invalidVaultIdentity }
        // Codable decoding bypasses the initializer's path-validation rules.
        return try ImVaultFileIdentity(vaultID: identity.vaultID,
                                       relativePath: identity.relativePath)
    }

    public static func documentDigest(for value: String) throws -> String? {
        try components(value)?.documentDigest
    }

    /// Only non-nil for v3 links explicitly tied to one audited source
    /// section. A hash is a locator hint, not proof that the card is correct.
    public static func sectionDigest(for value: String) throws -> String? {
        try components(value)?.sectionDigest
    }
}
