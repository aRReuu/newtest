import Foundation
import XCTest
@testable import ImpressReviewCore

final class ImpressChatPOCTransportTests: XCTestCase {
    private func replay(_ string: String, provider: ImpressChatPOCProviderProtocol,
                        cuts: [Int]) throws -> (outputs: [ImpressChatPOCOutput], complete: Bool) {
        let bytes = Array(string.utf8)
        var state = ImpressChatPOCReplay(provider: provider)
        var results: [ImpressChatPOCOutput] = []
        var cursor = 0, i = 0
        while cursor < bytes.count {
            let amount = min(cuts[i % cuts.count], bytes.count - cursor)
            results += try state.append(Data(bytes[cursor..<(cursor + amount)]))
            cursor += amount
            i += 1
        }
        results += try state.finish()
        return (results, state.normalizer.isCompleted)
    }

    func testOpenAIByteFracturesPreserveUnicodeAndTerminal() throws {
        let wire = [
            ": heartbeat",
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好🌱\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"👩‍💻 e\u{301}\"}}]}",
            "",
            "data: [DONE]",
            ""
        ].joined(separator: "\r\n") + "\r\n"
        let expected: [ImpressChatPOCOutput] = [.delta("你好🌱"), .delta("👩‍💻 e\u{301}"),
                                                .completed]
        for cuts in [[1], [2, 5, 1, 3, 7], [4096]] {
            let result = try replay(wire, provider: .openAIChat, cuts: cuts)
            XCTAssertEqual(result.outputs, expected)
            XCTAssertTrue(result.complete)
        }
    }

    func testAnthropicAndResponsesProtocolsNormalizeWithoutFalseFinish() throws {
        let anthropic = "event: content_block_delta\n" +
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"拆解\"}}\n\n" +
            "event: message_delta\n" +
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n" +
            "event: message_stop\n" + "data: {\"type\":\"message_stop\"}\n\n"
        let a = try replay(anthropic, provider: .anthropicMessages, cuts: [1, 7, 3])
        XCTAssertEqual(a.outputs, [.delta("拆解"), .completed])
        XCTAssertTrue(a.complete)
        let response = "event: response.output_text.delta\r" +
            "data: {\"delta\":\"first\"}\r\r" +
            "event: response.completed\r" +
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\r\r"
        let b = try replay(response, provider: .openAIResponses, cuts: [1, 2])
        XCTAssertEqual(b.outputs, [.delta("first"), .completed])
        XCTAssertTrue(b.complete)
    }

    func testGeminiChunkDeltasFollowOfficialStreamingSemantics() throws {
        let a = #"data: {"candidates":[{"content":{"parts":[{"text":"中文"}]}}]}"#
        let b = #"data: {"candidates":[{"content":{"parts":[{"text":"🌱"}]},"finishReason":"STOP"}]}"#
        let result = try replay(a + "\n\n" + b + "\n\n",
                                provider: .geminiGenerateContent, cuts: [1, 19, 2])
        XCTAssertEqual(result.outputs, [.delta("中文"), .delta("🌱"), .completed])
    }

    func testGeminiInterleavedThoughtSummariesNeverEnterCompletedVisibleAnswer() throws {
        // Real Gemini GenerateContent Parts explicitly tag thought summaries.
        // They must never contaminate the displayed answer, future text-only
        // history or a subsequent knowledge-revision proposal.
        let mixed = #"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"内部摘要🔒"},{"text":"结论："},{"thought":true,"text":"不应入库"},{"thought":false,"text":"安全🌱"}]}}]}"#
        let terminal = #"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"仅供诊断"},{"text":"。"}]},"finishReason":"STOP"}]}"#
        for cuts in [[1], [2, 7, 13], [4096]] {
            let result = try replay(mixed + "\n\n" + terminal + "\n\n",
                                    provider: .geminiGenerateContent, cuts: cuts)
            XCTAssertEqual(result.outputs,
                [.delta("结论：安全🌱"), .delta("。"), .completed])
            XCTAssertTrue(result.complete)
            XCTAssertFalse(result.outputs.contains(.delta("内部摘要🔒")))
        }
        // A wire-level STOP with thoughts only has no visible assistant text.
        // The production controller must still reject a completed empty reply.
        let thoughtOnly = #"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"只有思路，没有答复"}]},"finishReason":"STOP"}]}"#
        let empty = try replay(thoughtOnly + "\n\n",
                               provider: .geminiGenerateContent, cuts: [3])
        XCTAssertEqual(empty.outputs, [.completed])
        XCTAssertTrue(empty.complete)
        let safetyStop = #"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"内部摘要"},{"text":"未完成"}]},"finishReason":"SAFETY"}]}"#
        let denied = try replay(safetyStop + "\n\n",
                                provider: .geminiGenerateContent, cuts: [5])
        XCTAssertEqual(denied.outputs, [.delta("未完成"), .failed])
        XCTAssertFalse(denied.complete)
    }

    func testTruncatedOrSafetyStopNeverMarksAnswerCompleted() throws {
        let truncated = "data: " +
            #"{"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"# +
            "\n\n"
        let one = try replay(truncated, provider: .openAIChat, cuts: [2])
        XCTAssertEqual(one.outputs, [.delta("partial"), .failed])
        XCTAssertFalse(one.complete)

        let anthropic = "event: message_delta\n" +
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"# +
            "\n\nevent: message_stop\n" +
            #"data: {"type":"message_stop"}"# + "\n\n"
        let two = try replay(anthropic, provider: .anthropicMessages, cuts: [9])
        XCTAssertEqual(two.outputs, [.failed])
        XCTAssertFalse(two.complete)

        let gemini = "data: " +
            #"{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}"# +
            "\n\n"
        let three = try replay(gemini, provider: .geminiGenerateContent, cuts: [15])
        XCTAssertEqual(three.outputs, [.delta("partial"), .failed])
        XCTAssertFalse(three.complete)
    }

    func testResponsesSpoofedOrIncompleteTerminalCannotComplete() throws {
        let validDelta = "event: response.output_text.delta\n" +
            #"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n"
        for terminal in [
            #"{"type":"response.completed"}"#,
            #"{"type":"response.completed","response":{"status":"incomplete"}}"#,
            #"{"type":"response.completed","response":{"status":"failed"}}"#
        ] {
            let wire = validDelta + "event: response.completed\n" +
                "data: " + terminal + "\n\n"
            let result = try replay(wire, provider: .openAIResponses, cuts: [1, 3, 41])
            XCTAssertEqual(result.outputs, [.delta("partial"), .failed])
            XCTAssertFalse(result.complete)
        }
        var spoof = ImpressChatPOCEventNormalizer(provider: .openAIResponses)
        XCTAssertThrowsError(try spoof.consume(ImpressChatPOCSSEEvent(
            event: "response.completed", id: nil, data:
                #"{"type":"response.output_text.delta","delta":"partial"}"#)))
        XCTAssertFalse(spoof.isCompleted)
        var anthropicSpoof = ImpressChatPOCEventNormalizer(provider: .anthropicMessages)
        XCTAssertThrowsError(try anthropicSpoof.consume(ImpressChatPOCSSEEvent(
            event: "message_stop", id: nil, data:
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}"#)))
        XCTAssertFalse(anthropicSpoof.isCompleted)
    }

    func testUnterminatedNetworkStreamNeverCompletesAIMessage() throws {
        let incomplete = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
        let result = try replay(incomplete, provider: .openAIChat, cuts: [1])
        XCTAssertEqual(result.outputs, [.delta("partial")])
        XCTAssertFalse(result.complete)
    }

    func testMultilineDataAndCommentsRespectSSEBoundary() throws {
        var wire = ImpressChatPOCSSEDecoder()
        let bytes = Data(": keepalive\nid: 91\nevent: custom\n".utf8) +
                    Data("data: hello\ndata: world\n\n".utf8)
        let events = try wire.append(bytes)
        XCTAssertEqual(events, [ImpressChatPOCSSEEvent(event: "custom", id: "91",
                                                       data: "hello\nworld")])
        XCTAssertEqual(wire.dispatchedCount, 1)
    }

    func testMalformedAndOversizedFramesFailClosed() throws {
        var broken = ImpressChatPOCSSEDecoder()
        XCTAssertThrowsError(try broken.append(Data([0xff, 0x0a]))) { error in
            XCTAssertEqual(error as? ImpressChatPOCTransportError, .invalidUTF8)
        }
        var oversized = ImpressChatPOCSSEDecoder()
        let huge = Data(repeating: 97, count: ImpressChatPOCSSEDecoder.maximumBufferBytes + 1)
        XCTAssertThrowsError(try oversized.append(huge)) { error in
            XCTAssertEqual(error as? ImpressChatPOCTransportError, .tooLarge)
        }
        var normalized = ImpressChatPOCEventNormalizer(provider: .openAIChat)
        XCTAssertThrowsError(try normalized.consume(
            ImpressChatPOCSSEEvent(event: nil, id: nil, data: "{bad")))
        XCTAssertEqual(try normalized.consume(
            ImpressChatPOCSSEEvent(event: nil, id: nil, data: "[DONE]")), [.completed])
        XCTAssertThrowsError(try normalized.consume(
            ImpressChatPOCSSEEvent(event: nil, id: nil, data:
                #"{"choices":[{"delta":{"content":"late"}}]}"#)))
    }



    func testTypedTerminalAndErrorTaggedDONECannotClaimCompletion() throws {
        // An OpenAI-compatible gateway may emit an error header with a bogus
        // DONE data line. This is an error, never a finished assistant reply.
        var chat = ImpressChatPOCEventNormalizer(provider: .openAIChat)
        XCTAssertEqual(try chat.consume(ImpressChatPOCSSEEvent(
            event: "error", id: nil, data: "[DONE]")), [.failed])
        XCTAssertFalse(chat.isCompleted)
        XCTAssertTrue(chat.isFailed)

        // Responses and Anthropic terminal headers require a matching JSON
        // type. Absence must not count as agreement with the SSE event header.
        var responses = ImpressChatPOCEventNormalizer(provider: .openAIResponses)
        XCTAssertThrowsError(try responses.consume(ImpressChatPOCSSEEvent(
            event: "response.completed", id: nil,
            data: #"{"response":{"status":"completed"}}"#))) { error in
            XCTAssertEqual(error as? ImpressChatPOCTransportError, .invalidEvent)
        }
        XCTAssertFalse(responses.isCompleted)

        var anthropic = ImpressChatPOCEventNormalizer(provider: .anthropicMessages)
        _ = try anthropic.consume(ImpressChatPOCSSEEvent(
            event: "message_delta", id: nil,
            data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#))
        XCTAssertThrowsError(try anthropic.consume(ImpressChatPOCSSEEvent(
            event: "message_stop", id: nil, data: #"{"status":"ok"}"#))) { error in
            XCTAssertEqual(error as? ImpressChatPOCTransportError, .invalidEvent)
        }
        XCTAssertFalse(anthropic.isCompleted)

        // Legal text deltas may arrive with only a typed SSE header, as
        // covered by the existing Anthropic/Responses normalization fixture.
        // This is NOT sufficient for a terminal completion event.
        var legalDelta = ImpressChatPOCEventNormalizer(provider: .openAIResponses)
        XCTAssertEqual(try legalDelta.consume(ImpressChatPOCSSEEvent(
            event: "response.output_text.delta", id: nil,
            data: #"{"delta":"仍然有效🌱"}"#)),
            [.delta("仍然有效🌱")])
        XCTAssertFalse(legalDelta.isCompleted)
        var wrongDelta = ImpressChatPOCEventNormalizer(provider: .openAIResponses)
        XCTAssertThrowsError(try wrongDelta.consume(ImpressChatPOCSSEEvent(
            event: "response.output_text.delta", id: nil,
            data: #"{"type":"response.completed","delta":"伪造"}"#))) { error in
            XCTAssertEqual(error as? ImpressChatPOCTransportError, .invalidEvent)
        }
        XCTAssertFalse(wrongDelta.isCompleted)
        // The untyped Responses text-delta exception does not apply to
        // Anthropic stop-reason frames.
        var wrongAnthropic = ImpressChatPOCEventNormalizer(provider: .anthropicMessages)
        XCTAssertThrowsError(try wrongAnthropic.consume(ImpressChatPOCSSEEvent(
            event: "message_delta", id: nil,
            data: #"{"delta":{"stop_reason":"end_turn"}}"#))) { error in
            XCTAssertEqual(error as? ImpressChatPOCTransportError, .invalidEvent)
        }
        XCTAssertFalse(wrongAnthropic.isCompleted)

        // Standard compliant terminal events remain accepted.
        var valid = ImpressChatPOCEventNormalizer(provider: .openAIResponses)
        XCTAssertEqual(try valid.consume(ImpressChatPOCSSEEvent(
            event: "response.completed", id: nil,
            data: #"{"type":"response.completed","response":{"status":"completed"}}"#)),
            [.completed])
        XCTAssertTrue(valid.isCompleted)
    }

    func testTerminalMarkersAreScopedToTheirProviderAndReason() throws {
        for provider in [ImpressChatPOCProviderProtocol.openAIResponses,
                         .anthropicMessages, .geminiGenerateContent] {
            var state = ImpressChatPOCEventNormalizer(provider: provider)
            XCTAssertThrowsError(try state.consume(
                ImpressChatPOCSSEEvent(event: nil, id: nil, data: "[DONE]"))) { error in
                XCTAssertEqual(error as? ImpressChatPOCTransportError, .invalidEvent)
            }
            XCTAssertFalse(state.isCompleted)
        }
        var missingStopReason = ImpressChatPOCEventNormalizer(provider: .anthropicMessages)
        XCTAssertThrowsError(try missingStopReason.consume(
            ImpressChatPOCSSEEvent(event: "message_stop", id: nil,
                                   data: #"{"type":"message_stop"}"#)))
        XCTAssertFalse(missingStopReason.isCompleted)

        var toolOutput = ImpressChatPOCEventNormalizer(provider: .anthropicMessages)
        _ = try toolOutput.consume(ImpressChatPOCSSEEvent(
            event: "message_delta", id: nil,
            data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#))
        XCTAssertEqual(try toolOutput.consume(ImpressChatPOCSSEEvent(
            event: "message_stop", id: nil, data: #"{"type":"message_stop"}"#)),
            [.failed])
        XCTAssertFalse(toolOutput.isCompleted)
    }

    func testProviderErrorKeepsUnfinishedStatus() throws {
        var model = ImpressChatPOCEventNormalizer(provider: .anthropicMessages)
        XCTAssertEqual(try model.consume(ImpressChatPOCSSEEvent(
            event: "error", id: nil, data: #"{"error":{"message":"private"}} "#)),
            [.failed])
        XCTAssertFalse(model.isCompleted)
        XCTAssertTrue(model.isFailed)
    }
    func testEOFWithoutBlankFrameBoundaryNeverCommitsProviderTerminal() throws {
        let validDelta = "data: " +
            #"{"choices":[{"delta":{"content":"partial"}}]}"# + "\n\n"
        for unfinishedEnd in ["data: [DONE]", "data: [DONE]\n",
                               "data: [DONE]\r"] {
            let result = try replay(validDelta + unfinishedEnd,
                                    provider: .openAIChat, cuts: [1, 5, 8192])
            XCTAssertEqual(result.outputs, [.delta("partial")])
            XCTAssertFalse(result.complete)
        }
        let responses = "event: response.completed\n" +
            #"data: {"type":"response.completed"}"# + "\n"
        let incompleteResponses = try replay(responses, provider: .openAIResponses,
                                             cuts: [128])
        XCTAssertTrue(incompleteResponses.outputs.isEmpty)
        XCTAssertFalse(incompleteResponses.complete)

        let anthropic = "event: message_delta\n" +
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"# +
            "\n\nevent: message_stop\n" +
            #"data: {"type":"message_stop"}"# + "\n"
        let incompleteAnthropic = try replay(anthropic, provider: .anthropicMessages,
                                             cuts: [7])
        XCTAssertTrue(incompleteAnthropic.outputs.isEmpty)
        XCTAssertFalse(incompleteAnthropic.complete)

        let gemini = "data: " +
            #"{"candidates":[{"finishReason":"STOP"}]}"# + "\n"
        let incompleteGemini = try replay(gemini, provider: .geminiGenerateContent,
                                          cuts: [2, 64])
        XCTAssertTrue(incompleteGemini.outputs.isEmpty)
        XCTAssertFalse(incompleteGemini.complete)
    }

    func testFinalCRCanCloseRealBlankLineButNotUnterminatedData() throws {
        let complete = try replay("data: [DONE]\r\r",
                                  provider: .openAIChat, cuts: [1])
        XCTAssertEqual(complete.outputs, [.completed])
        XCTAssertTrue(complete.complete)
        let incomplete = try replay("data: [DONE]\r",
                                    provider: .openAIChat, cuts: [1])
        XCTAssertTrue(incomplete.outputs.isEmpty)
        XCTAssertFalse(incomplete.complete)
    }

    func testLargeNetworkReadWithManySmallEventsDoesNotHitFrameLimit() throws {
        let oneEvent = "data: " +
            #"{"choices":[{"delta":{"content":"🧠"}}]}"# + "\n\n"
        let count = 6_000
        let payload = String(repeating: oneEvent, count: count) + "data: [DONE]\n\n"
        XCTAssertGreaterThan(payload.utf8.count,
                             ImpressChatPOCSSEDecoder.maximumBufferBytes)
        let result = try replay(payload, provider: .openAIChat,
                                cuts: [payload.utf8.count])
        XCTAssertEqual(result.outputs.count, count + 1)
        XCTAssertEqual(result.outputs.first, .delta("🧠"))
        XCTAssertEqual(result.outputs.last, .completed)
        XCTAssertTrue(result.complete)
    }

    func testSlicedDataWithNonzeroBaseIndexRemainsDecodable() throws {
        let payload = Data("ignoredata: [DONE]\n\n".utf8)
        let sliced = payload.dropFirst(6)
        var decoder = ImpressChatPOCSSEDecoder()
        XCTAssertEqual(try decoder.append(sliced),
                       [ImpressChatPOCSSEEvent(event: nil, id: nil, data: "[DONE]")])
        XCTAssertTrue(try decoder.finish().isEmpty)
    }

}
