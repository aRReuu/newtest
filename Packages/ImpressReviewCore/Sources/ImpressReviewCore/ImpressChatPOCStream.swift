import Foundation

/// Offline-only typed streaming proof of concept. No HTTP, Vault or WCDB.
public struct ImpressChatPOCBlock: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case paragraph, heading, list, quote, code, table, math, divider
    }
    public let id: Int
    public let kind: Kind
    public let markdown: String
    public let headingLevel: Int
    public let stable: Bool
    public init(id: Int, kind: Kind, markdown: String,
                headingLevel: Int = 0, stable: Bool) {
        self.id = id; self.kind = kind; self.markdown = markdown
        self.headingLevel = headingLevel; self.stable = stable
    }
}

public enum ImpressChatPOCPhase: String, Sendable {
    case idle, streaming, completed, stopped, failed
}

/// Blank lines outside code/math finalize immutable blocks. Only the tail
/// is reclassified on new tokens; incomplete output never becomes completed.
public struct ImpressChatPOCStream: Sendable {
    public private(set) var phase: ImpressChatPOCPhase = .idle
    public private(set) var source = ""
    public private(set) var blocks: [ImpressChatPOCBlock] = []
    public private(set) var lastReparsedUTF8Count = 0
    /// Instrumentation for offline POC-05; bytes reparsed are an algorithmic
    /// cost proxy, NOT wall-clock latency, CPU utilization or device FPS.
    public private(set) var cumulativeReparsedUTF8Count = 0
    public private(set) var eventCount = 0
    public private(set) var peakDirtyTailUTF8Count = 0
    public var committedBlockCount: Int { fixed.count }
    private var fixed: [ImpressChatPOCBlock] = []
    private var tail = ""

    public init() {}
    public mutating func start() {
        source = ""; blocks = []; fixed = []; tail = ""
        lastReparsedUTF8Count = 0
        cumulativeReparsedUTF8Count = 0
        eventCount = 0
        peakDirtyTailUTF8Count = 0
        phase = .streaming
    }
    public mutating func append(_ fragment: String) {
        guard phase == .streaming, !fragment.isEmpty else { return }
        source += fragment; tail += fragment
        eventCount += 1
        if let point = Self.lastSafeBoundary(in: tail) {
            fixed += Self.parse(String(tail[..<point]), offset: fixed.count, stable: true)
            tail = String(tail[point...])
        }
        lastReparsedUTF8Count = tail.utf8.count
        cumulativeReparsedUTF8Count += lastReparsedUTF8Count
        peakDirtyTailUTF8Count = max(peakDirtyTailUTF8Count, lastReparsedUTF8Count)
        blocks = fixed + Self.parse(tail, offset: fixed.count, stable: false)
    }
    public mutating func finish() {
        guard phase == .streaming else { return }
        fixed += Self.parse(tail, offset: fixed.count, stable: true)
        blocks = fixed; tail = ""; lastReparsedUTF8Count = 0; phase = .completed
    }
    public mutating func stop() { if phase == .streaming { phase = .stopped } }
    public mutating func fail() { if phase == .streaming { phase = .failed } }
    public static func parseOnce(_ source: String) -> [ImpressChatPOCBlock] {
        parse(source, offset: 0, stable: true)
    }
    /// Split by Unicode newline scalars, not Swift Character. Swift treats
    /// CRLF as a single grapheme; String.split(separator: "\n") misses it.
    /// Indexes retain the exact source span and original line endings.
    private struct SourceLine {
        let text: String
        let start: String.Index
        let contentEnd: String.Index
        let nextStart: String.Index
        let terminated: Bool
    }

    private static func logicalLines(_ input: String) -> [SourceLine] {
        let scalars = input.unicodeScalars
        var start = scalars.startIndex
        var cursor = start
        var output: [SourceLine] = []
        while cursor < scalars.endIndex {
            let current = scalars[cursor].value
            if current == 10 || current == 13 {
                var next = scalars.index(after: cursor)
                if current == 13 && next < scalars.endIndex &&
                   scalars[next].value == 10 {
                    next = scalars.index(after: next)
                }
                output.append(SourceLine(
                    text: String(input[start..<cursor]), start: start,
                    contentEnd: cursor, nextStart: next, terminated: true))
                start = next
                cursor = next
            } else {
                cursor = scalars.index(after: cursor)
            }
        }
        output.append(SourceLine(
            text: String(input[start..<input.endIndex]), start: start,
            contentEnd: input.endIndex, nextStart: input.endIndex,
            terminated: false))
        return output
    }

    // CommonMark fenced-code openers must not be closed by a different
    // marker, a shorter run, or stray backticks inside ordinary content.
    private struct Fence: Equatable {
        let marker: Character
        let length: Int
    }

    private static func openingFence(_ line: String) -> Fence? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let trimmed = line.dropFirst(indentation)
        guard let marker = trimmed.first,
              marker == "\u{60}" || marker == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        // Backtick infos may not themselves contain a backtick.
        if marker == "\u{60}" && trimmed.dropFirst(count).contains("\u{60}") {
            return nil
        }
        return Fence(marker: marker, length: count)
    }

    private static func closesFence(_ line: String, _ active: Fence) -> Bool {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return false }
        let trimmed = line.dropFirst(indentation)
        let count = trimmed.prefix(while: { $0 == active.marker }).count
        guard count >= active.length else { return false }
        return trimmed.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func togglesMath(_ line: String) -> Bool {
        guard line.hasPrefix("$$") else { return false }
        return line == "$$" || !line.dropFirst(2).contains("$$")
    }

    private static func lastSafeBoundary(in text: String) -> String.Index? {
        let lines = logicalLines(text)
        var fenced: Fence?
        var math = false
        var last: String.Index?
        for row in lines {
            let line = row.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fenced {
                if closesFence(line, open) { fenced = nil }
            } else if !math, let open = openingFence(line) {
                fenced = open
            } else if togglesMath(trimmed) {
                math.toggle()
            }
            if trimmed.isEmpty && row.terminated && fenced == nil && !math {
                last = row.nextStart
            }
        }
        return last
    }
    private static func headingDepth(_ s: String) -> Int {
        let n = s.prefix(while: { $0 == "#" }).count
        return (1...6).contains(n) && s.dropFirst(n).first == " " ? n : 0
    }
    private static func isList(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return true }
        let digits = t.prefix(while: { $0.isNumber })
        return !digits.isEmpty && (t.dropFirst(digits.count).hasPrefix(". ") ||
                                  t.dropFirst(digits.count).hasPrefix(") "))
    }
    private static func parse(_ input: String, offset: Int,
                              stable: Bool) -> [ImpressChatPOCBlock] {
        var result: [ImpressChatPOCBlock] = []
        var pending: [SourceLine] = []
        var activeKind: ImpressChatPOCBlock.Kind?
        var activeHeading = 0
        var fenced: Fence?
        var math = false

        func flush() {
            let content: String
            if let first = pending.first, let last = pending.last {
                content = String(input[first.start..<last.contentEnd])
            } else {
                content = ""
            }
            pending = []
            guard !content.isEmpty else {
                activeKind = nil
                activeHeading = 0
                return
            }
            let kind = activeKind ?? .paragraph
            result.append(ImpressChatPOCBlock(
                id: offset + result.count, kind: kind, markdown: content,
                headingLevel: activeHeading, stable: stable))
            activeKind = nil
            activeHeading = 0
        }

        let lines = logicalLines(input)
        for row in lines {
            let line = row.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fenced {
                pending.append(row)
                if closesFence(line, open) {
                    fenced = nil
                    flush()
                }
                continue
            }
            if math {
                pending.append(row)
                if togglesMath(trimmed) {
                    math = false
                    flush()
                }
                continue
            }
            if trimmed.isEmpty { flush(); continue }

            if let open = openingFence(line) {
                flush()
                activeKind = .code
                pending.append(row)
                fenced = open
                continue
            }
            if trimmed.hasPrefix("$$") {
                flush()
                activeKind = .math
                pending.append(row)
                if togglesMath(trimmed) {
                    math = true
                } else {
                    flush()
                }
                continue
            }
            let heading = headingDepth(trimmed)
            if heading > 0 {
                flush()
                activeKind = .heading
                activeHeading = heading
                pending.append(row)
                flush()
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                flush()
                activeKind = .divider
                pending.append(row)
                flush()
                continue
            }

            let isDelimiter = trimmed.contains("---") &&
                trimmed.replacingOccurrences(of: "|", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespaces).isEmpty
            if pending.count == 1, activeKind == .paragraph,
               pending[0].text.contains("|"), isDelimiter {
                activeKind = .table
                pending.append(row)
                continue
            }
            let kind: ImpressChatPOCBlock.Kind =
                trimmed.hasPrefix(">") ? .quote : (isList(trimmed) ? .list : .paragraph)
            let continuesList = activeKind == .list &&
                (kind == .list || line.first == " " || line.first == "\t")
            let continuesTable = activeKind == .table && trimmed.contains("|")
            if activeKind != nil && activeKind != kind &&
                !continuesList && !continuesTable {
                flush()
            }
            if activeKind == nil { activeKind = kind }
            pending.append(row)
        }
        flush()
        return result
    }
}
