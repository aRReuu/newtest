import Foundation

/// Lexically identified Obsidian embeds in the exact supplied UTF-8 document.
/// Callers MUST retain the original source revision; offsets are meaningful
/// only for those bytes, never for a styled/WebKit/LLM projection.
public struct ImpressVaultEmbedReference: Sendable, Equatable {
    public let target: String
    public let startUTF8: Int
    public let endUTF8: Int
}

public enum ImpressVaultEmbedLocator {
    public static func references(in markdown: String) -> [ImpressVaultEmbedReference] {
        let bytes = Array(markdown.utf8)
        var result: [ImpressVaultEmbedReference] = []
        var lineStart = 0
        var fence: (marker: UInt8, count: Int)?
        var inComment = false
        var inlineTicks = 0

        func has(_ pos: Int, _ pattern: [UInt8], _ end: Int) -> Bool {
            pos + pattern.count <= end &&
                bytes[pos..<pos + pattern.count].elementsEqual(pattern)
        }
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count && bytes[lineEnd] != 10 && bytes[lineEnd] != 13 {
                lineEnd += 1
            }
            var next = lineEnd
            if next < bytes.count {
                if bytes[next] == 13 && next + 1 < bytes.count && bytes[next + 1] == 10 {
                    next += 2
                } else {
                    next += 1
                }
            }

            var trimmed = lineStart
            var leading = 0
            while trimmed < lineEnd && bytes[trimmed] == 32 {
                trimmed += 1
                leading += 1
            }
            if leading <= 3 && trimmed < lineEnd &&
               (bytes[trimmed] == 96 || bytes[trimmed] == 126) {
                let mark = bytes[trimmed]
                var cursor = trimmed
                while cursor < lineEnd && bytes[cursor] == mark { cursor += 1 }
                let length = cursor - trimmed
                if length >= 3 {
                    if let existing = fence {
                        if mark == existing.marker && length >= existing.count {
                            fence = nil
                        }
                    } else {
                        fence = (mark, length)
                    }
                    inlineTicks = 0
                    lineStart = next
                    continue
                }
            }
            if fence != nil || leading >= 4 {
                lineStart = next
                continue
            }

            var offset = lineStart
            while offset < lineEnd {
                if inComment {
                    if has(offset, [45, 45, 62], lineEnd) {
                        inComment = false
                        offset += 3
                    } else {
                        offset += 1
                    }
                    continue
                }
                if inlineTicks == 0 && has(offset, [60, 33, 45, 45], lineEnd) {
                    inComment = true
                    offset += 4
                    continue
                }
                if bytes[offset] == 96 {
                    var cursor = offset
                    while cursor < lineEnd && bytes[cursor] == 96 { cursor += 1 }
                    let length = cursor - offset
                    if inlineTicks == 0 { inlineTicks = length }
                    else if inlineTicks == length { inlineTicks = 0 }
                    offset = cursor
                    continue
                }
                if inlineTicks == 0 && has(offset, [33, 91, 91], lineEnd) {
                    let begin = offset
                    let contentStart = offset + 3
                    var close = contentStart
                    let maximum = min(lineEnd, contentStart + 512)
                    while close + 1 < maximum &&
                          !(bytes[close] == 93 && bytes[close + 1] == 93) {
                        close += 1
                    }
                    if close + 1 < maximum &&
                       bytes[close] == 93 && bytes[close + 1] == 93 {
                        let target = String(decoding: bytes[contentStart..<close], as: UTF8.self)
                        if !target.isEmpty && !target.contains("\u{FFFD}") {
                            result.append(ImpressVaultEmbedReference(
                                target: target, startUTF8: begin, endUTF8: close + 2))
                        }
                        offset = close + 2
                        continue
                    }
                }
                offset += 1
            }
            // Inline backtick code spans may continue onto the next physical line.
            lineStart = next
        }
        return result
    }
}
