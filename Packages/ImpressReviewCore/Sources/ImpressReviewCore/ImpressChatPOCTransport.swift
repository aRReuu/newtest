import Foundation

/// Zero-network transport contract used by the Chat renderer POC.
/// Decode raw UTF-8 bytes before interpreting SSE: a network read may end
/// in the middle of a Chinese glyph, emoji, CRLF or JSON string.
public enum ImpressChatPOCTransportError: Error, Equatable, Sendable {
    case tooLarge, invalidUTF8, malformedJSON, invalidEvent, unexpectedAfterTerminal
}

public struct ImpressChatPOCSSEEvent: Equatable, Sendable {
    public let event: String?
    public let id: String?
    public let data: String
    public init(event: String?, id: String?, data: String) {
        self.event = event
        self.id = id
        self.data = data
    }
}

public struct ImpressChatPOCSSEDecoder: Sendable {
    public static let maximumBufferBytes = 256 * 1024
    public private(set) var dispatchedCount = 0
    private var buffer = Data()
    private var lines: [String] = []
    private var activeEvent: String?
    private var activeID: String?
    private var dataBytes = 0

    public init() {}

    /// Arbitrary fragmented reads, including a single byte per call.
    public mutating func append(_ bytes: Data) throws -> [ImpressChatPOCSSEEvent] {
        var produced: [ImpressChatPOCSSEEvent] = []
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            // Bound one unfinished frame, not a network read containing
            // thousands of independently framed events.
            let available = Self.maximumBufferBytes - buffer.count
            guard available > 0 else { throw ImpressChatPOCTransportError.tooLarge }
            // Small batches avoid quadratic prefix removal for bulk URLSession reads.
            let length = min(bytes.distance(from: cursor, to: bytes.endIndex),
                             min(available, 16 * 1024))
            let next = bytes.index(cursor, offsetBy: length)
            buffer.append(contentsOf: bytes[cursor..<next])
            cursor = next
            while let delimiter = Self.findLineDelimiter(in: buffer) {
                let data = Data(buffer.prefix(delimiter.offset))
                buffer.removeSubrange(0..<delimiter.end)
                try consumeLine(data, into: &produced)
            }
        }
        return produced
    }

    /// EOF is not a completion signal: only an SSE frame ending with a blank
    /// line may contain a terminal marker. Retain no uncommitted event at EOF.
    public mutating func finish() throws -> [ImpressChatPOCSSEEvent] {
        var produced: [ImpressChatPOCSSEEvent] = []
        // A final CR is a valid line ending; append() delayed it only to
        // distinguish CRLF fragmented over separate network reads.
        if buffer.last == 13 {
            try consumeLine(Data(buffer.dropLast()), into: &produced)
        }
        buffer.removeAll(keepingCapacity: true)
        activeEvent = nil
        activeID = nil
        lines.removeAll(keepingCapacity: true)
        dataBytes = 0
        return produced
    }

    private static func findLineDelimiter(in bytes: Data) -> (offset: Int, end: Int)? {
        for (index, byte) in bytes.enumerated() {
            if byte == 10 { return (index, index + 1) }
            if byte == 13 {
                guard index + 1 < bytes.count else { return nil }
                return (index, bytes[index + 1] == 10 ? index + 2 : index + 1)
            }
        }
        return nil
    }

    private mutating func consumeLine(
        _ bytes: Data, into output: inout [ImpressChatPOCSSEEvent]
    ) throws {
        guard let line = String(data: bytes, encoding: .utf8),
              !line.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw ImpressChatPOCTransportError.invalidUTF8 }
        guard !line.isEmpty else { dispatch(into: &output); return }
        if line.hasPrefix(":") { return } // standard SSE keepalive
        let head = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(head.first ?? "")
        var value = head.count == 2 ? String(head[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch key {
        case "event":
            guard value.utf8.count <= 128 else { throw ImpressChatPOCTransportError.tooLarge }
            activeEvent = value
        case "id":
            guard !value.contains("\u{0000}"), value.utf8.count <= 1024
            else { throw ImpressChatPOCTransportError.invalidEvent }
            activeID = value
        case "data":
            dataBytes += value.utf8.count + 1
            guard dataBytes <= Self.maximumBufferBytes else {
                throw ImpressChatPOCTransportError.tooLarge
            }
            lines.append(value)
        default:
            break // retry/unknown fields are not model content
        }
    }

    private mutating func dispatch(into output: inout [ImpressChatPOCSSEEvent]) {
        if !lines.isEmpty {
            output.append(ImpressChatPOCSSEEvent(
                event: activeEvent, id: activeID, data: lines.joined(separator: "\n")))
            dispatchedCount += 1
        }
        activeEvent = nil
        activeID = nil
        lines.removeAll(keepingCapacity: true)
        dataBytes = 0
    }
}

public enum ImpressChatPOCProviderProtocol: Sendable {
    case openAIChat, openAIResponses, anthropicMessages, geminiGenerateContent
}

public enum ImpressChatPOCOutput: Equatable, Sendable {
    case delta(String)
    case completed
    case failed
}

/// Provider-specific events have one common UI contract. No HTTP or keys.
/// A missing explicit terminal event is *never* converted to completed.
public struct ImpressChatPOCEventNormalizer: Sendable {
    public let provider: ImpressChatPOCProviderProtocol
    public private(set) var isCompleted = false
    public private(set) var isFailed = false
    private var anthropicStopReason: String?

    public init(provider: ImpressChatPOCProviderProtocol) { self.provider = provider }

    public mutating func consume(
        _ event: ImpressChatPOCSSEEvent
    ) throws -> [ImpressChatPOCOutput] {
        guard !isCompleted && !isFailed else {
            // OpenAI Chat Completions may send [DONE] after finish_reason.
            // Other providers never use that sentinel to end their response.
            if isCompleted && provider == .openAIChat &&
               event.event == nil && event.data == "[DONE]" { return [] }
            throw ImpressChatPOCTransportError.unexpectedAfterTerminal
        }
        // A provider-reported error must never masquerade as OpenAI's [DONE]
        // sentinel, even if the error frame carries that exact data string.
        if event.event == "error" || event.event == "response.failed" {
            isFailed = true
            return [.failed]
        }
        if event.data == "[DONE]" {
            guard provider == .openAIChat, event.event == nil else {
                throw ImpressChatPOCTransportError.invalidEvent
            }
            return terminal()
        }
        guard let object = try JSONSerialization.jsonObject(
            with: Data(event.data.utf8)) as? [String: Any] else {
            throw ImpressChatPOCTransportError.malformedJSON
        }
        if object["error"] != nil {
            isFailed = true
            return [.failed]
        }
        // Terminal and text frames of typed SSE protocols must carry their
        // actual JSON event type. An absent "type" is NOT agreement with an
        // untrusted event header such as "response.completed"/"message_stop".
        // Ignore untyped custom keepalives, but fail closed for known frames.
        if provider == .openAIResponses || provider == .anthropicMessages {
            if let headerType = event.event {
                let payloadType = object["type"] as? String
                // Keep known Anthropic typed frames and completion terminals strict:
                // a header alone cannot establish a completed answer or stop reason.
                // Legacy Responses text deltas may omit redundant JSON "type"; if
                // ANY frame does provide type, it must match the SSE event header.
                let requiresType = [
                    "response.completed", "response.failed", "response.incomplete",
                    "message_stop", "message_delta", "content_block_delta"
                ].contains(headerType)
                if (requiresType && payloadType != headerType) ||
                   (payloadType != nil && payloadType != headerType) {
                    throw ImpressChatPOCTransportError.invalidEvent
                }
            }
        }
        switch provider {
        case .openAIChat:
            guard let choice = (object["choices"] as? [[String: Any]])?.first
            else { return [] } // role-only metadata
            var events: [ImpressChatPOCOutput] = []
            if let delta = choice["delta"] as? [String: Any],
               let text = delta["content"] as? String, !text.isEmpty {
                events.append(.delta(text))
            }
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                if reason == "stop" { events += terminal() }
                else { isFailed = true; events.append(.failed) }
            }
            return events
        case .openAIResponses:
            let type = event.event ?? (object["type"] as? String ?? "")
            if type == "response.completed" {
                guard let response = object["response"] as? [String: Any],
                      response["status"] as? String == "completed" else {
                    isFailed = true
                    return [.failed]
                }
                return terminal()
            }
            if type == "response.incomplete" {
                isFailed = true
                return [.failed]
            }
            if type == "response.failed" {
                isFailed = true
                return [.failed]
            }
            if type == "response.output_text.delta",
               let text = object["delta"] as? String, !text.isEmpty {
                return [.delta(text)]
            }
            return []
        case .anthropicMessages:
            let type = event.event ?? (object["type"] as? String ?? "")
            if type == "message_delta",
               let delta = object["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                anthropicStopReason = reason
            }
            if type == "message_stop" {
                switch anthropicStopReason {
                case "end_turn", "stop_sequence":
                    return terminal()
                case .some:
                    isFailed = true
                    return [.failed]
                case .none:
                    // A bare stream close is not evidence of a complete
                    // answer, even if partial text has been seen.
                    throw ImpressChatPOCTransportError.invalidEvent
                }
            }
            if type == "content_block_delta",
               let delta = object["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return [.delta(text)]
            }
            return []
        case .geminiGenerateContent:
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first
            else { return [] }
            let content = candidate["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            // Google's streamed GenerateContentResponse parts are chunks,
            // not the cumulative full answer. SDK samples append chunk.text.
            // Gemini GenerateContent can interleave thought-summary Parts with
            // user-visible answer Parts. Only final-answer text is eligible for
            // the transcript, future text-only history and duplex suggestions.
            // Thought signatures are NOT used by this plain-text-only adapter;
            // do not misrepresent it as a function-calling replay protocol.
            let chunk = parts.filter { $0["thought"] as? Bool != true }
                .compactMap { $0["text"] as? String }.joined()
            var output: [ImpressChatPOCOutput] = chunk.isEmpty ? [] : [.delta(chunk)]
            if let reason = candidate["finishReason"] as? String, !reason.isEmpty {
                if reason == "STOP" { output += terminal() }
                else { isFailed = true; output.append(.failed) }
            }
            return output
        }
    }

    private mutating func terminal() -> [ImpressChatPOCOutput] {
        guard !isCompleted else { return [] }
        isCompleted = true
        return [.completed]
    }
}

/// An explicit bounded offline wire replay for deterministic UIKit tests.
public struct ImpressChatPOCReplay: Sendable {
    public var decoder = ImpressChatPOCSSEDecoder()
    public var normalizer: ImpressChatPOCEventNormalizer

    public init(provider: ImpressChatPOCProviderProtocol) {
        normalizer = ImpressChatPOCEventNormalizer(provider: provider)
    }

    public mutating func append(_ bytes: Data) throws -> [ImpressChatPOCOutput] {
        try decoder.append(bytes).flatMap { event in try normalizer.consume(event) }
    }

    public mutating func finish() throws -> [ImpressChatPOCOutput] {
        try decoder.finish().flatMap { event in try normalizer.consume(event) }
    }
}
