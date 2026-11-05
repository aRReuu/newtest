import XCTest
import Foundation
import ImpressReviewCore
@testable import aReuImpress_iPhone

/// Zero-network native request/response wire test. No paid model, Key or Vault.
final class ImpressAIHTTPStreamingIntegrationTests: XCTestCase {
    private final class OfflineSSEProtocol: URLProtocol {
        static var body = Data()
        static var code = 200
        static var contentType = "text/event-stream; charset=utf-8"
        static var capturedRequest: URLRequest?
        static var requestCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.capturedRequest = request
            Self.requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.code, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": Self.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Genuine streaming URLProtocol: publishes trusted SSE frames but keeps
    /// the HTTP response open indefinitely. Never calls didFinishLoading.
    /// This catches a completed UI response blocked on a lingering socket.
    private final class HangingTerminalSSEProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let frames = [
                "event: response.output_text.delta",
                #"data: {"type":"response.output_text.delta","delta":"终止前的真实文本"}"#,
                "", "event: response.completed",
                #"data: {"type":"response.completed","response":{"status":"completed"}}"#,
                "", ""
            ].joined(separator: "\n")
            client?.urlProtocol(self, didLoad: Data(frames.utf8))
            // Intentionally no URLProtocolDidFinishLoading: the provider's
            // connection may remain open after declaring completion.
        }
        override func stopLoading() {}
    }

    func testValidatedTerminalCompletesWhileHTTPSSEConnectionStaysOpen() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingTerminalSSEProtocol.self]
        let client = ImpressAIHTTPClient(
            session: URLSession(configuration: configuration))
        let route = syntheticRoute(provider: .openAI, wire: .responses,
                                   modelID: "synthetic-still-open")
        let stream = try await client.converseStream(
            route: route, system: "仅离线测试",
            turns: [ImpressAIChatTurn(role: .user, text: "安全终止")])
        let finished = expectation(description: "validated SSE terminal closes before HTTP EOF")
        let collector = Task {
            var outputs: [ImpressChatPOCOutput] = []
            do {
                for try await value in stream { outputs.append(value) }
                XCTAssertEqual(outputs, [.delta("终止前的真实文本"), .completed],
                    "A trusted terminal must release the composer without socket EOF")
            } catch {
                XCTFail("Validated terminal must not be converted into an error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 4)
        collector.cancel()
    }

    func testFreeModelRequestStreamsAndTerminatesWithoutNetwork() async throws {
        let first = #"{"choices":[{"delta":{"content":"中文 🧠"}}]}"#
        let second = #"{"choices":[{"delta":{"content":"＋证据"},"finish_reason":"stop"}]}"#
        let lines = ["data: " + first, "", "data: " + second, "",
                     "data: [DONE]", "", ""]
        OfflineSSEProtocol.body = Data(lines.joined(separator: "\n").utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineSSEProtocol.self]
        let client = ImpressAIHTTPClient(session: URLSession(configuration: config))
        let connection = ImpressAIOpenCodeFreeQA.connection()
        let model = ImpressAIModel(connectionID: connection.id,
                                  identifier: ImpressAIOpenCodeFreeQA.preferredModelID)
        let route = ImpressAIResolvedRoute(connection: connection, model: model)
        let stream = try await client.converseStream(
            route: route, system: "仅离线测试", turns: [
                ImpressAIChatTurn(role: .user, text: "请解释")
            ])
        var deltas: [ImpressChatPOCOutput] = []
        for try await value in stream { deltas.append(value) }
        XCTAssertEqual(deltas, [.delta("中文 🧠"), .delta("＋证据"), .completed])
        let request = try XCTUnwrap(OfflineSSEProtocol.capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.httpMethod, "POST")
        // URLProtocol may receive a POST body as a non-rewindable stream.
        // Inspect the exact request builder used by converseStream instead.
        let prepared = try await client.debugPreparedStreamRequest(
            route: route, system: "仅离线测试",
            turns: [ImpressAIChatTurn(role: .user, text: "请解释")])
        let data = try XCTUnwrap(prepared.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String,
                       ImpressAIOpenCodeFreeQA.preferredModelID)
    }

    func testUnexpectedEOFMustThrowRatherThanComplete() async throws {
        let partialJSON = #"{"choices":[{"delta":{"content":"未完成"}}]}"#
        OfflineSSEProtocol.body = Data(("data: " + partialJSON + "\n\n").utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineSSEProtocol.self]
        let client = ImpressAIHTTPClient(session: URLSession(configuration: config))
        let connection = ImpressAIOpenCodeFreeQA.connection()
        let model = ImpressAIModel(connectionID: connection.id,
                                  identifier: ImpressAIOpenCodeFreeQA.preferredModelID)
        let stream = try await client.converseStream(
            route: ImpressAIResolvedRoute(connection: connection, model: model),
            system: "只进行本地合成测试",
            turns: [ImpressAIChatTurn(role: .user, text: "测试")])
        do {
            for try await item in stream {
                XCTAssertNotEqual(item, .completed)
            }
            XCTFail("SSE EOF without terminal must fail")
        } catch {
            // The stored reply remains partial; it cannot be approved.
        }
    }

    private func syntheticRoute(provider: ImpressAIProvider,
                                wire: ImpressAIProtocol,
                                modelID: String) -> ImpressAIResolvedRoute {
        // Explicitly fake hostname and no authentication. URLProtocol intercepts
        // before any socket could be opened, so all providers cost zero.
        let connection = ImpressAIConnection(title: "Offline protocol fixture",
            provider: provider, apiProtocol: wire,
            baseURL: URL(string: "https://impress-fixture.invalid/v1")!,
            authentication: .noAuthentication)
        return ImpressAIResolvedRoute(connection: connection,
            model: ImpressAIModel(connectionID: connection.id, identifier: modelID))
    }

    private func zeroNetworkReplay(_ wire: String,
                                   route: ImpressAIResolvedRoute) async throws
        -> ([ImpressChatPOCOutput], URLRequest) {
        OfflineSSEProtocol.body = Data(wire.utf8)
        OfflineSSEProtocol.code = 200
        OfflineSSEProtocol.contentType = "text/event-stream"
        OfflineSSEProtocol.capturedRequest = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineSSEProtocol.self]
        let client = ImpressAIHTTPClient(session: URLSession(configuration: config))
        let stream = try await client.converseStream(route: route,
            system: "合成 system", turns: [
                ImpressAIChatTurn(role: .user, text: "合成 user")])
        var events: [ImpressChatPOCOutput] = []
        for try await event in stream { events.append(event) }
        let request = try XCTUnwrap(OfflineSSEProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        return (events, try await client.debugPreparedStreamRequest(
            route: route, system: "合成 system",
            turns: [ImpressAIChatTurn(role: .user, text: "合成 user")]))
    }

    func testNativeOpenAIResponsesRequiresExplicitCompleteStatus() async throws {
        let route = syntheticRoute(provider: .openAI, wire: .responses,
                                   modelID: "synthetic-responses")
        let data = [
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","delta":"第一段"}"#, "",
            "event: response.completed",
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#, "", ""
        ].joined(separator: "\n")
        let (events, prepared) = try await zeroNetworkReplay(data, route: route)
        XCTAssertEqual(events, [.delta("第一段"), .completed])
        XCTAssertEqual(prepared.url?.lastPathComponent, "responses")
        let body = try XCTUnwrap(prepared.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertNotNil(json["input"])
        XCTAssertNil(json["messages"])
    }


    func testNativeProviderTerminalForgeryNeverYieldsCompleted() async throws {
        // Real converseStream(), synthetic URLProtocol only: model/Key/Vault
        // never leave the process. Keep the partial reply visible but forbid
        // a forged terminal from authorizing completed-history semantics.
        let fixtures: [(ImpressAIResolvedRoute, String)] = [
            (syntheticRoute(provider: .openAI, wire: .chatCompletions,
                modelID: "offline-chat"),
             [
                #"data: {"choices":[{"delta":{"content":"partial"}}]}"#, "",
                "event: error", "data: [DONE]", "", ""
             ].joined(separator: "\n")),
            (syntheticRoute(provider: .openAI, wire: .responses,
                modelID: "offline-responses"),
             [
                "event: response.output_text.delta",
                #"data: {"type":"response.output_text.delta","delta":"partial"}"#, "",
                "event: response.completed",
                #"data: {"response":{"status":"completed"}}"#, "", ""
             ].joined(separator: "\n")),
            (syntheticRoute(provider: .anthropic, wire: .anthropicMessages,
                modelID: "offline-anthropic"),
             [
                "event: content_block_delta",
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}"#, "",
                "event: message_delta",
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "",
                "event: message_stop",
                #"data: {"status":"ok"}"#, "", ""
             ].joined(separator: "\n"))
        ]
        for (route, wire) in fixtures {
            OfflineSSEProtocol.body = Data(wire.utf8)
            OfflineSSEProtocol.code = 200
            OfflineSSEProtocol.contentType = "text/event-stream"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineSSEProtocol.self]
            let client = ImpressAIHTTPClient(
                session: URLSession(configuration: configuration))
            let stream = try await client.converseStream(route: route,
                system: "离线协议错误隔离", turns: [
                    ImpressAIChatTurn(role: .user, text: "测试")
                ])
            var received: [ImpressChatPOCOutput] = []
            var rejected = false
            do {
                for try await event in stream { received.append(event) }
            } catch {
                rejected = true
            }
            XCTAssertTrue(rejected, "Malformed terminal must throw for \(route.effectiveProtocol)")
            XCTAssertEqual(received, [.delta("partial")])
            XCTAssertFalse(received.contains(.completed))
        }
    }

    func testNativeAnthropicMessagesRequiresMessageStopAndEndTurn() async throws {
        let route = syntheticRoute(provider: .anthropic, wire: .anthropicMessages,
                                   modelID: "synthetic-anthropic")
        let data = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"文本 🧠"}}"#, "",
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "",
            "event: message_stop", #"data: {"type":"message_stop"}"#, "", ""
        ].joined(separator: "\n")
        let (events, request) = try await zeroNetworkReplay(data, route: route)
        XCTAssertEqual(events, [.delta("文本 🧠"), .completed])
        XCTAssertEqual(request.url?.lastPathComponent, "messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"),
                       "2023-06-01")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["model"] as? String, "synthetic-anthropic")
        XCTAssertNotNil(json["system"])
    }

    /// G2 regression: the *production* request serializer sees the approved
    /// text file in only the final user turn. All routes are zero-network
    /// synthetic providers; no credentials or personal Vault are required.
    func testExplicitTextFileAppearsOnlyInCurrentUserWireTurnAcrossProviders() async throws {
        typealias Attachment = ImpressChatEphemeralTextAttachment
        typealias Consent = ImpressChatEphemeralFileConsent
        struct FrozenRoute: Encodable {
            let connection: ImpressAIConnection
            let model: ImpressAIModel
        }

        let privateMarker = "IMPR_PRIVATE_ATTACHMENT_WIRE_SENTINEL_20261027"
        let file = try Attachment.prepare(
            data: Data(("Only this approved request: " + privateMarker).utf8),
            filename: "offline.md", fileExtension: "md")
        let selectedID = UUID()
        let conversationID = UUID()
        let userInput = "Summarize the attached document"
        let olderUserInput = "A previous question without attachments"
        let providers: [(ImpressAIProvider, ImpressAIProtocol)] = [
            (.openAI, .chatCompletions),
            (.openAI, .responses),
            (.anthropic, .anthropicMessages),
            (.gemini, .geminiGenerateContent)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineSSEProtocol.self]
        let client = ImpressAIHTTPClient(session: URLSession(configuration: configuration))

        for (provider, wire) in providers {
            let connection = ImpressAIConnection(
                title: "Synthetic local test", provider: provider,
                apiProtocol: wire,
                baseURL: URL(string: "https://offline-fixture.invalid/v1")!,
                authentication: .noAuthentication)
            let model = ImpressAIModel(
                connectionID: connection.id, identifier: "synthetic-no-network")
            let route = ImpressAIResolvedRoute(connection: connection, model: model)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let destination = Consent.Destination(
                providerID: connection.id, modelID: model.id,
                modelName: model.identifier,
                endpoint: connection.baseURL.absoluteString,
                wireProtocol: String(describing: route.effectiveProtocol),
                sessionID: conversationID,
                routeFingerprint: try encoder.encode(FrozenRoute(
                    connection: connection, model: model)))
            let approval = try Consent.Snapshot.freeze(
                destination: destination, input: userInput,
                previewIDs: [selectedID], prepared: [file])
            let approvedTurn = try approval.approvedUserTurn(
                destination: destination, input: userInput,
                previewIDs: [selectedID], prepared: [file])
            let turns = [
                ImpressAIChatTurn(role: .user, text: olderUserInput),
                ImpressAIChatTurn(role: .assistant, text: "Earlier response"),
                ImpressAIChatTurn(role: .user, text: approvedTurn)
            ]
            // This is the same request builder converseStream uses, without
            // opening a socket or invoking a paid Provider.
            let request = try await client.debugPreparedStreamRequest(
                route: route, system: "Local synthetic instruction", turns: turns)
            let bytes = try XCTUnwrap(request.httpBody)
            let serialized = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            XCTAssertEqual(serialized.components(separatedBy: privateMarker).count - 1, 1)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let wireText: String
            switch wire {
            case .chatCompletions:
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertEqual(messages.last?["role"] as? String, "user")
                XCTAssertEqual(messages[1]["content"] as? String, olderUserInput)
                wireText = try XCTUnwrap(messages.last?["content"] as? String)
            case .responses:
                let input = try XCTUnwrap(json["input"] as? [[String: Any]])
                XCTAssertEqual(input.last?["role"] as? String, "user")
                XCTAssertEqual(input.first?["content"] as? String, olderUserInput)
                wireText = try XCTUnwrap(input.last?["content"] as? String)
            case .anthropicMessages:
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertEqual(messages.last?["role"] as? String, "user")
                XCTAssertEqual(messages.first?["content"] as? String, olderUserInput)
                wireText = try XCTUnwrap(messages.last?["content"] as? String)
            case .geminiGenerateContent:
                let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
                XCTAssertEqual(contents.last?["role"] as? String, "user")
                let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
                wireText = try XCTUnwrap(parts.last?["text"] as? String)
                let olderParts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
                XCTAssertEqual(olderParts.first?["text"] as? String, olderUserInput)
            }
            XCTAssertEqual(wireText, approvedTurn)

            // The approval is deliberately absent from the next request.
            // Re-sending the private bytes would require another explicit
            // attachment selection and consent flow, not a history replay.
            let nextRequest = try await client.debugPreparedStreamRequest(
                route: route, system: "Local synthetic instruction",
                turns: [ImpressAIChatTurn(
                    role: .user, text: "Another question, no attached file")])
            let nextBody = try XCTUnwrap(nextRequest.httpBody)
            let nextJSON = try XCTUnwrap(String(data: nextBody, encoding: .utf8))
            XCTAssertFalse(nextJSON.contains(privateMarker))
        }
    }

    func testNativeGeminiSSEUsesAltSSEAndModelRole() async throws {
        let route = syntheticRoute(provider: .gemini, wire: .geminiGenerateContent,
                                   modelID: "synthetic-gemini")
        let data = [
            #"data: {"candidates":[{"content":{"parts":[{"text":"中文"}]}}]}"#, "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"🌱"}]},"finishReason":"STOP"}]}"#, "", ""
        ].joined(separator: "\n")
        let (events, request) = try await zeroNetworkReplay(data, route: route)
        XCTAssertEqual(events, [.delta("中文"), .delta("🌱"), .completed])
        XCTAssertTrue(request.url?.path.contains("streamGenerateContent") == true)
        let query = URLComponents(url: try XCTUnwrap(request.url),
                                  resolvingAgainstBaseURL: false)
        XCTAssertEqual(query?.queryItems?.first(where: { $0.name == "alt" })?.value,
                       "sse")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["contents"])
        XCTAssertNil(json["messages"])
    }

    func testNativeDeepSeekGLMAndCustomUseCorrectChatCompletionsWire() async throws {
        for provider in [ImpressAIProvider.deepSeek, .zhipu, .custom] {
            let route = syntheticRoute(provider: provider,
                wire: .chatCompletions, modelID: "synthetic-compatible")
            let data = [
                #"data: {"choices":[{"delta":{"content":"合成答复"}}]}"#, "",
                #"data: {"choices":[{"finish_reason":"stop"}]}"#, "",
                "data: [DONE]", "", ""
            ].joined(separator: "\n")
            let (events, request) = try await zeroNetworkReplay(data, route: route)
            XCTAssertEqual(events, [.delta("合成答复"), .completed])
            XCTAssertEqual(request.url?.lastPathComponent, "completions")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertNotNil(json["messages"])
            XCTAssertNil(json["input"])
        }
    }

    func testNativeHTTPRateLimitAndNonSSEFailWithoutAutomaticSecondRequest() async throws {
        let connection = ImpressAIOpenCodeFreeQA.connection()
        let model = ImpressAIModel(connectionID: connection.id,
                                  identifier: ImpressAIOpenCodeFreeQA.preferredModelID)
        let route = ImpressAIResolvedRoute(connection: connection, model: model)
        defer {
            OfflineSSEProtocol.code = 200
            OfflineSSEProtocol.contentType = "text/event-stream; charset=utf-8"
        }
        for (statusCode, contentType) in [
            (429, "text/event-stream"), (200, "application/json")
        ] {
            OfflineSSEProtocol.code = statusCode
            OfflineSSEProtocol.contentType = contentType
            OfflineSSEProtocol.requestCount = 0
            OfflineSSEProtocol.body = Data(
                #"{"choices":[{"delta":{"content":"should-not-emit"}}]}"#.utf8)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OfflineSSEProtocol.self]
            let client = ImpressAIHTTPClient(session: URLSession(configuration: config))
            let stream = try await client.converseStream(route: route,
                system: "offline only", turns: [
                    ImpressAIChatTurn(role: .user, text: "test")])
            var outputs: [ImpressChatPOCOutput] = []
            var didThrow = false
            do {
                for try await value in stream { outputs.append(value) }
            } catch {
                didThrow = true
            }
            XCTAssertTrue(didThrow)
            XCTAssertTrue(outputs.isEmpty,
                "An HTTP error or non-SSE response cannot become visible model text")
            XCTAssertEqual(OfflineSSEProtocol.requestCount, 1,
                "A failed HTTP attempt must never silently retry or incur more requests")
        }
    }

    func testNativeResponsesIncompleteRetainsDeltaAndThrowsNotCompleted() async throws {
        let route = syntheticRoute(provider: .openAI, wire: .responses,
                                   modelID: "synthetic-incomplete")
        OfflineSSEProtocol.body = Data([
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","delta":"保留片段"}"#, "",
            "event: response.incomplete",
            #"data: {"type":"response.incomplete","response":{"status":"incomplete"}}"#, "", ""
        ].joined(separator: "\n").utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineSSEProtocol.self]
        let client = ImpressAIHTTPClient(session: URLSession(configuration: config))
        let stream = try await client.converseStream(route: route,
            system: "合成前提", turns: [
                ImpressAIChatTurn(role: .user, text: "合成提问")])
        var outputs: [ImpressChatPOCOutput] = []
        var didThrow = false
        do {
            for try await result in stream { outputs.append(result) }
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Incomplete response cannot be accepted as completed")
        XCTAssertEqual(outputs, [.delta("保留片段")],
            "The already delivered partial response must remain visible")
    }


    func testImageInputRequiresExplicitModelConsentAndSafeJPEG() async throws {
        let connection = ImpressAIConnection(title: "Synthetic offline",
            provider: .openAI, apiProtocol: .chatCompletions,
            baseURL: URL(string: "https://impress-fixture.invalid/v1")!,
            authentication: .noAuthentication)
        let model = ImpressAIModel(connectionID: connection.id,
            identifier: "fake-vision-model")
        let client = ImpressAIHTTPClient(
            session: URLSession(configuration: .ephemeral))
        let turns = [ImpressAIChatTurn(role: .user, text: "Describe")]
        let jpeg = ImpressAIImagePayload(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0x00, 0xFF, 0xD9]),
            displayName: "synthetic.jpg")
        do {
            _ = try await client.debugPreparedStreamRequest(
                route: ImpressAIResolvedRoute(connection: connection, model: model),
                system: "Synthetic", turns: turns, images: [jpeg])
            XCTFail("No model-capability consent: no image can leave the app")
        } catch ImpressAIServiceError.unsupportedImageInput {}
        var opted = model
        opted.supportsImageInput = true
        let route = ImpressAIResolvedRoute(connection: connection, model: opted)
        for invalid in [
            ImpressAIImagePayload(jpeg: Data("not-a-jpeg".utf8),
                                  displayName: "bad"),
            ImpressAIImagePayload(jpeg: Data(repeating: 0xFF, count: 400_001),
                                  displayName: "too-big")
        ] {
            do {
                _ = try await client.debugPreparedStreamRequest(route: route,
                    system: "Synthetic", turns: turns, images: [invalid])
                XCTFail("Malformed or oversized image must fail before network")
            } catch ImpressAIServiceError.unsupportedImageInput {}
        }
        let qaConnection = ImpressAIOpenCodeFreeQA.connection()
        let qaModel = ImpressAIModel(connectionID: qaConnection.id,
            identifier: ImpressAIOpenCodeFreeQA.preferredModelID,
            supportsImageInput: true)
        do {
            _ = try await client.debugPreparedStreamRequest(
                route: ImpressAIResolvedRoute(connection: qaConnection, model: qaModel),
                system: "QA", turns: turns, images: [jpeg])
            XCTFail("Anonymous free QA cannot be silently promoted to image usage")
        } catch ImpressAIServiceError.unsupportedImageInput {}
        let legacy = try JSONEncoder().encode(model)
        let restored = try JSONDecoder().decode(ImpressAIModel.self, from: legacy)
        XCTAssertNil(restored.supportsImageInput,
            "Old persisted model entries must decode with image sending disabled")
    }

    func testImageOnlyTurnUsesOneApprovedImagePartForEachProvider() async throws {
        // Real production URLRequest builder, but entirely offline fixtures.
        let photo = ImpressAIImagePayload(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0x00, 0xFF, 0xD9]),
            displayName: "approved-offline.jpg")
        let encoded = photo.jpeg.base64EncodedString()
        let client = ImpressAIHTTPClient(
            session: URLSession(configuration: .ephemeral))
        let imageOnly = [ImpressAIChatTurn(role: .user, text: "")]
        for (provider, wire) in [
            (ImpressAIProvider.openAI, ImpressAIProtocol.chatCompletions),
            (.openAI, .responses), (.anthropic, .anthropicMessages),
            (.gemini, .geminiGenerateContent)
        ] {
            let connection = ImpressAIConnection(title: "Offline",
                provider: provider, apiProtocol: wire,
                baseURL: URL(string: "https://impress-fixture.invalid/v1")!,
                authentication: .noAuthentication)
            let model = ImpressAIModel(connectionID: connection.id,
                identifier: "synthetic-vision", supportsImageInput: true)
            let route = ImpressAIResolvedRoute(connection: connection, model: model)
            let req = try await client.debugPreparedStreamRequest(
                route: route, system: "Synthetic", turns: imageOnly,
                images: [photo])
            let raw = try XCTUnwrap(req.httpBody)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: raw) as? [String: Any])
            let parts: [[String: Any]]
            switch wire {
            case .chatCompletions, .anthropicMessages:
                let rows = try XCTUnwrap(payload["messages"] as? [[String: Any]])
                parts = try XCTUnwrap(rows.last?["content"] as? [[String: Any]])
            case .responses:
                let rows = try XCTUnwrap(payload["input"] as? [[String: Any]])
                parts = try XCTUnwrap(rows.last?["content"] as? [[String: Any]])
            case .geminiGenerateContent:
                let rows = try XCTUnwrap(payload["contents"] as? [[String: Any]])
                parts = try XCTUnwrap(rows.last?["parts"] as? [[String: Any]])
            }
            XCTAssertEqual(parts.count, 1,
                "Image-only request must not create an empty text content block")
            XCTAssertNil(parts[0]["text"])
            let canonical = try XCTUnwrap(String(data: raw, encoding: .utf8))
                .replacingOccurrences(of: "\\/", with: "/")
            XCTAssertEqual(canonical.components(separatedBy: encoded).count - 1, 1,
                "Only the explicitly approved JPEG is serialized once")
            do {
                _ = try await client.debugPreparedStreamRequest(
                    route: route, system: "Synthetic", turns: imageOnly)
                XCTFail("Empty text-only message must be rejected without image consent")
            } catch ImpressAIServiceError.tooLarge {
                // Expected: no request can be built from an empty turn alone.
            }
        }
    }

    func testEachProviderUsesItsOwnImageWireShapeWithoutSendingHistoryImages() async throws {
        // Only mock prepared URLRequests; no actual provider or paid model is called.
        let photo = ImpressAIImagePayload(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0x00, 0xFF, 0xD9]),
            displayName: "consented.jpg")
        let encoded = photo.jpeg.base64EncodedString()
        let client = ImpressAIHTTPClient(
            session: URLSession(configuration: .ephemeral))
        let turns = [ImpressAIChatTurn(role: .user, text: "Earlier"),
                     ImpressAIChatTurn(role: .assistant, text: "Previous"),
                     ImpressAIChatTurn(role: .user, text: "What is shown?")]
        for (provider, wire) in [
            (ImpressAIProvider.openAI, ImpressAIProtocol.chatCompletions),
            (.openAI, .responses), (.anthropic, .anthropicMessages),
            (.gemini, .geminiGenerateContent)
        ] {
            let connection = ImpressAIConnection(title: "Offline",
                provider: provider, apiProtocol: wire,
                baseURL: URL(string: "https://impress-fixture.invalid/v1")!,
                authentication: .noAuthentication)
            let model = ImpressAIModel(connectionID: connection.id,
                identifier: "synthetic-vision", supportsImageInput: true)
            let route = ImpressAIResolvedRoute(connection: connection, model: model)
            let req = try await client.debugPreparedStreamRequest(
                route: route, system: "No private data", turns: turns,
                images: [photo])
            let bytes = try XCTUnwrap(req.httpBody)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            // JSONSerialization may escape "/" as "\/" in base64, although
            // the parsed transport field contains the unmodified JPEG bytes.
            // Canonicalize only JSON solidus escapes, and assert the exact
            // approved content occurs once rather than weakening its check.
            let canonical = try XCTUnwrap(String(data: bytes, encoding: .utf8))
                .replacingOccurrences(of: "\\/", with: "/")
            XCTAssertEqual(canonical.components(separatedBy: encoded).count - 1, 1,
                "One approved JPEG must occur exactly once in its outbound request")
            switch wire {
            case .chatCompletions:
                let rows = try XCTUnwrap(payload["messages"] as? [[String: Any]])
                XCTAssertEqual(rows[1]["content"] as? String, "Earlier")
                let parts = try XCTUnwrap(rows.last?["content"] as? [[String: Any]])
                XCTAssertEqual(parts.first?["text"] as? String, "What is shown?")
                let image = try XCTUnwrap(parts.last?["image_url"] as? [String: String])
                XCTAssertEqual(image["url"], "data:image/jpeg;base64," + encoded)
            case .responses:
                let rows = try XCTUnwrap(payload["input"] as? [[String: Any]])
                XCTAssertEqual(rows[0]["content"] as? String, "Earlier")
                let parts = try XCTUnwrap(rows.last?["content"] as? [[String: Any]])
                XCTAssertEqual(parts.last?["image_url"] as? String,
                               "data:image/jpeg;base64," + encoded)
                XCTAssertEqual(payload["store"] as? Bool, false)
            case .anthropicMessages:
                let rows = try XCTUnwrap(payload["messages"] as? [[String: Any]])
                XCTAssertEqual(rows[0]["content"] as? String, "Earlier")
                let parts = try XCTUnwrap(rows.last?["content"] as? [[String: Any]])
                let src = try XCTUnwrap(parts.last?["source"] as? [String: String])
                XCTAssertEqual(src["media_type"], "image/jpeg")
                XCTAssertEqual(src["data"], encoded)
            case .geminiGenerateContent:
                let rows = try XCTUnwrap(payload["contents"] as? [[String: Any]])
                let parts = try XCTUnwrap(rows.last?["parts"] as? [[String: Any]])
                let inline = try XCTUnwrap(parts.last?["inlineData"] as? [String: String])
                XCTAssertEqual(inline["mimeType"], "image/jpeg")
                XCTAssertEqual(inline["data"], encoded)
            }
            let ordinary = try await client.debugPreparedStreamRequest(
                route: route, system: "No private data", turns: turns)
            XCTAssertFalse(String(data: try XCTUnwrap(ordinary.httpBody),
                encoding: .utf8)?.contains(encoded) ?? false,
                "Text-only existing requests must remain text-only")
        }
    }
}
