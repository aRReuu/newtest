import Foundation
import XCTest
@testable import ImpressReviewCore

final class ImpressAIContractsTests: XCTestCase {
    private let safeURL = URL(string: "https://api.example.test/v1")!
    private func fixture() throws -> (ImpressAIRegistry, ImpressAIConnection, ImpressAIModel) {
        let c = ImpressAIConnection(title: "API A", provider: .deepSeek,
                                    apiProtocol: .chatCompletions, baseURL: safeURL,
                                    credentialID: UUID())
        let m = ImpressAIModel(connectionID: c.id, identifier: "model-A", jsonVerified: true)
        let cfg = try ImpressAIRegistry(connections: [c], models: [m],
                         routes: [ImpressAIRoute(task: .questionGeneration, primaryModelID: m.id)])
        return (cfg, c, m)
    }

    func testIndependentProvidersModelsAndRoutes() throws {
        let (_, c1, m1) = try fixture()
        let c2 = ImpressAIConnection(title: "Another key same service", provider: .deepSeek,
                                     apiProtocol: .chatCompletions, baseURL: safeURL,
                                     credentialID: UUID())
        let m2 = ImpressAIModel(connectionID: c2.id, identifier: m1.identifier, jsonVerified: true)
        let cfg = try ImpressAIRegistry(connections: [c1, c2], models: [m1, m2],
                         routes: [
                           .init(task: .questionGeneration, primaryModelID: m1.id),
                           .init(task: .conversation, primaryModelID: m2.id)
                         ])
        XCTAssertEqual(try cfg.resolve(.questionGeneration).connection.id, c1.id)
        XCTAssertEqual(try cfg.resolve(.conversation).model.id, m2.id)
    }

    func testSecretsNotSerializedAsValues() throws {
        let (cfg, _, _) = try fixture()
        let dump = String(decoding: try JSONEncoder().encode(cfg), as: UTF8.self)
        XCTAssertTrue(dump.contains("credentialID"))
        XCTAssertFalse(dump.contains("API_KEY_VALUE"))
        XCTAssertFalse(dump.contains("Bearer"))
    }

    func testUnsafeEndpointsRejected() {
        for string in ["http://example.com/v1", "https://user:pass@example.com/v1",
                       "https://example.com/v1?key=hidden", "https://example.com:444/v1"] {
            let c = ImpressAIConnection(title: "Bad", provider: .custom,
                   apiProtocol: .chatCompletions, baseURL: URL(string: string)!)
            XCTAssertThrowsError(try ImpressAIRegistry(connections: [c]))
        }
    }

    func testProviderWireProtocolMustMatch() throws {
        let bad = ImpressAIConnection(title: "Bad", provider: .anthropic,
                                      apiProtocol: .chatCompletions, baseURL: safeURL)
        XCTAssertThrowsError(try ImpressAIRegistry(connections: [bad]))
        let ok = ImpressAIConnection(title: "Custom", provider: .custom,
                                     apiProtocol: .chatCompletions, baseURL: safeURL)
        XCTAssertNoThrow(try ImpressAIRegistry(connections: [ok]))
    }

    func testNoAutomaticCrossProviderFallback() throws {
        let (_, c1, m1) = try fixture()
        let c2 = ImpressAIConnection(title: "OpenAI", provider: .openAI,
                                     apiProtocol: .responses, baseURL: safeURL, credentialID: UUID())
        let m2 = ImpressAIModel(connectionID: c2.id, identifier: "model-2", jsonVerified: true)
        let route = ImpressAIRoute(task: .questionGeneration, primaryModelID: m1.id,
                                   fallbackModelID: m2.id)
        XCTAssertThrowsError(try ImpressAIRegistry(connections: [c1,c2], models: [m1,m2], routes: [route]))
        let explicit = ImpressAIRoute(task: .questionGeneration, primaryModelID: m1.id,
                            fallbackModelID: m2.id, crossProviderAuthorized: true)
        XCTAssertNoThrow(try ImpressAIRegistry(connections: [c1,c2], models: [m1,m2], routes: [explicit]))
    }

    func testUnverifiedModelCannotReadPrivateNotes() throws {
        let (_, c, m) = try fixture()
        var failed = m
        failed.jsonVerified = false
        let r = try ImpressAIRegistry(connections: [c], models: [failed],
                             routes: [.init(task: .questionGeneration, primaryModelID: failed.id)])
        XCTAssertThrowsError(try r.resolve(.questionGeneration))
    }

    private func source() -> ImpressAISource {
        ImpressAISource(vaultID: "v1", relativePath: "学习/原理.md",
                        documentSHA256: String(repeating: "a", count: 64), heading: "应用")
    }

    func testFiveQuestionRequestAndReadOnlySourceEvidence() throws {
        let s = source()
        let e = ImpressAIExcerpt(id: "fragment-01", source: s, text: "已有资料解释机制")
        let c = ImpressAIQuestionCandidate(question: "在什么时候采用?", answer: "当条件满足时使用。",
                    dimension: .application, evidenceIDs: ["fragment-01"])
        let p = ImpressAIQuestionPool(source: s, excerpts: [e], requestedCount: 5,
                                    modelProfileID: UUID(), candidates: [c])
        let audit = ImpressAIQuestionValidator.audit(p)
        XCTAssertEqual(audit.candidates[0].issues, [])
        XCTAssertEqual(try ImpressAIQuestionValidator.validatedSelection(audit).count, 1)
    }

    func testFabricatedEvidenceBlocked() throws {
        let s = source()
        let e = ImpressAIExcerpt(id: "1", source: s, text: "x")
        let candidate = ImpressAIQuestionCandidate(question: "问题", answer: "答案", dimension: .mechanism,
                                                   evidenceIDs: ["does-not-exist"])
        let p = ImpressAIQuestionPool(source: s, excerpts: [e],
                modelProfileID: UUID(), candidates: [candidate])
        XCTAssertFalse(ImpressAIQuestionValidator.audit(p).candidates[0].issues.isEmpty)
        XCTAssertThrowsError(try ImpressAIQuestionValidator.validatedSelection(p))
    }

    func testDuplicateCandidatesAndExistingCardsBlocked() {
        let s = source()
        let e = ImpressAIExcerpt(id: "x", source: s, text: "source text")
        let a = ImpressAIQuestionCandidate(question: "为什么？", answer: "答案", dimension: .mechanism,
                                         evidenceIDs: ["x"])
        var b = a
        b.id = UUID()
        let p = ImpressAIQuestionPool(source: s, excerpts: [e],
                modelProfileID: UUID(), candidates: [a,b])
        let audit = ImpressAIQuestionValidator.audit(p, existingQuestions: ["为什么？"])
        XCTAssertFalse(audit.candidates[0].issues.isEmpty)
        XCTAssertFalse(audit.candidates[1].issues.isEmpty)
    }

    func testSelectionsRejectBlankAndOverCount() throws {
        let s = source()
        let e = ImpressAIExcerpt(id: "x", source: s, text: "source")
        let blank = ImpressAIQuestionCandidate(question: "  ", answer: "answer",
                          dimension: .comparison, evidenceIDs: ["x"])
        let p = ImpressAIQuestionPool(source: s, excerpts: [e], requestedCount: 1,
                             modelProfileID: UUID(), candidates: [blank])
        XCTAssertThrowsError(try ImpressAIQuestionValidator.validatedSelection(p))
        var excluded = p
        excluded.candidates[0].question = "ok"
        excluded.candidates[0].selected = false
        XCTAssertThrowsError(try ImpressAIQuestionValidator.validatedSelection(excluded))
    }

    func testStrictJSONRejectsMarkdownFencesAndFakeNarrative() throws {
        XCTAssertThrowsError(try ImpressAIQuestionPrompt.decode("Here are your questions: {}"))
        XCTAssertThrowsError(try ImpressAIQuestionPrompt.decode("```json\n{}\n```"))
        let json = """
        {"questions":[{"question":"解释原因？","answer":"有明确机制。",
        "dimension":"mechanism","evidenceIDs":["e1"]}]}
        """
        XCTAssertEqual(try ImpressAIQuestionPrompt.decode(json).count, 1)
    }

    func testNoBlindUploadLargeContext() throws {
        let s = source()
        let e = ImpressAIExcerpt(id: "x", source: s, text: String(repeating: "q", count: 512),
                                sectionHeading: "验证的章节标题")
        XCTAssertThrowsError(try ImpressAIQuestionPrompt.input([e], maxBytes: 120))
        XCTAssertTrue(try ImpressAIQuestionPrompt.input([e]).contains("fragment") == false)
        let payload = try ImpressAIQuestionPrompt.input([e])
        XCTAssertTrue(payload.contains("text"))
        XCTAssertTrue(payload.contains("验证的章节标题"))
        XCTAssertFalse(payload.contains(s.relativePath))
        XCTAssertFalse(payload.contains(s.vaultID))
        XCTAssertFalse(payload.contains(s.documentSHA256))
    }
}

extension ImpressAIContractsTests {
    func testExtraProviderPresetsAndArbitraryCustomCompany() throws {
        let profiles: [(ImpressAIProvider, ImpressAIProtocol, String)] = [
            (.zhipu, .chatCompletions, "https://open.bigmodel.cn/api/paas/v4"),
            (.commandCode, .chatCompletions, "https://api.commandcode.ai/provider/v1"),
            (.openCode, .responses, "https://opencode.ai/zen/go/v1"),
            (.custom, .anthropicMessages, "https://third-party.example/v2")
        ]
        for (provider, wire, endpoint) in profiles {
            let c = ImpressAIConnection(title: "Any brand: " + provider.rawValue,
                                        provider: provider, apiProtocol: wire,
                                        baseURL: try XCTUnwrap(URL(string: endpoint)),
                                        credentialID: UUID())
            XCTAssertNoThrow(try ImpressAIRegistry(connections: [c]))
        }
    }

    func testGatewayAllowsMixedWireFormatsOnSingleKey() throws {
        let gateway = ImpressAIConnection(title: "Command Code", provider: .commandCode,
                apiProtocol: .chatCompletions,
                baseURL: URL(string: "https://api.commandcode.ai/provider/v1")!,
                credentialID: UUID())
        let chat = ImpressAIModel(connectionID: gateway.id, identifier: "open/model",
                                 jsonVerified: true, protocolOverride: .chatCompletions)
        let anthropic = ImpressAIModel(connectionID: gateway.id,
                                 identifier: "claude/example",
                                 jsonVerified: true, protocolOverride: .anthropicMessages,
                                 jsonMode: .promptOnly)
        let registry = try ImpressAIRegistry(connections: [gateway], models: [chat, anthropic],
                  routes: [.init(task: .questionGeneration, primaryModelID: chat.id),
                           .init(task: .conversation, primaryModelID: anthropic.id)])
        XCTAssertEqual(try registry.resolve(.questionGeneration).effectiveProtocol, .chatCompletions)
        XCTAssertEqual(try registry.resolve(.conversation).effectiveProtocol, .anthropicMessages)
        XCTAssertEqual(gateway.effectiveAuthentication, .bearer)
        XCTAssertEqual(anthropic.jsonMode, .promptOnly)
    }

    func testCustomAuthenticationHeaderAllowedButProtectedHeadersBlocked() throws {
        let valid = ImpressAIConnection(title: "Any HTTPS API", provider: .custom,
                  apiProtocol: .chatCompletions, baseURL: safeURL,
                  credentialID: UUID(), authentication: .customHeader,
                  customHeaderName: "X-Custom-Private-Token")
        XCTAssertNoThrow(try ImpressAIRegistry(connections: [valid]))
        for forbidden in ["Authorization", "Cookie", "Content-Type", "Host",
                          "x-goog-api-key", "X-Key\\nInjected", "X Key", ""] {
            var invalid = valid
            invalid.customHeaderName = forbidden
            XCTAssertThrowsError(try ImpressAIRegistry(connections: [invalid]))
        }
    }

    func testAuthModeNoneRequiresNoCredentialButBearerDoes() throws {
        let emptyKey = ImpressAIConnection(title: "TLS Gateway", provider: .custom,
                 apiProtocol: .chatCompletions, baseURL: safeURL,
                 authentication: .noAuthentication)
        let verified = ImpressAIModel(connectionID: emptyKey.id, identifier: "my-model",
                                      jsonVerified: true)
        let routing = [ImpressAIRoute(task: .questionGeneration, primaryModelID: verified.id)]
        let accepted = try ImpressAIRegistry(connections: [emptyKey],
                                             models: [verified], routes: routing)
        XCTAssertEqual(try accepted.resolve(.questionGeneration).model.id, verified.id)
        var needsKey = emptyKey
        needsKey.authentication = .bearer
        let rejected = try ImpressAIRegistry(connections: [needsKey],
                                             models: [verified], routes: routing)
        XCTAssertThrowsError(try rejected.resolve(.questionGeneration))
    }

    func testCustomEndpointPathsAreRelativeSafeAndDisableModelListing() throws {
        let paths = ImpressAIEndpointPaths(modelsPath: "",
                     chatPath: "api/v5/chat/completions",
                     responsesPath: "sdk/responses", messagesPath: "provider/messages")
        XCTAssertNoThrow(try paths.validate())
        XCTAssertEqual(paths.path(for: .chatCompletions), "api/v5/chat/completions")
        XCTAssertEqual(paths.path(for: .anthropicMessages), "provider/messages")
        for value in ["../keys", "/admin", "https://elsewhere.com", "m/../../secret",
                      "chat?token=x", "chat%2Fsecret", "x//y", "x\\y", "chat#part", "a/./b"] {
            XCTAssertFalse(ImpressAIEndpointPaths.safePath(value))
        }
        XCTAssertTrue(ImpressAIEndpointPaths.safePath("", allowEmpty: true))
        XCTAssertFalse(ImpressAIEndpointPaths.safePath(""))
    }

    func testCustomGatewayProtocolOverrideDoesNotBypassProviderRestrictions() throws {
        let glm = ImpressAIConnection(title: "GLM", provider: .zhipu,
                 apiProtocol: .chatCompletions, baseURL: safeURL)
        let invalid = ImpressAIModel(connectionID: glm.id, identifier: "glm-custom",
                protocolOverride: .anthropicMessages)
        XCTAssertThrowsError(try ImpressAIRegistry(connections: [glm], models: [invalid]))
        XCTAssertTrue(ImpressAIRegistry.supported(.anthropicMessages, for: .commandCode))
        XCTAssertTrue(ImpressAIRegistry.supported(.responses, for: .openCode))
        XCTAssertFalse(ImpressAIRegistry.supported(.geminiGenerateContent, for: .zhipu))
    }

    func testLegacyV1RegistryDecodesWithoutNewOptionalCustomFields() throws {
        let (registry, connection, _) = try fixture()
        let original = try JSONEncoder().encode(registry)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var oldConnections = try XCTUnwrap(raw["connections"] as? [[String: Any]])
        oldConnections[0].removeValue(forKey: "authentication")
        oldConnections[0].removeValue(forKey: "customHeaderName")
        oldConnections[0].removeValue(forKey: "endpoints")
        raw["connections"] = oldConnections
        var oldModels = try XCTUnwrap(raw["models"] as? [[String: Any]])
        oldModels[0].removeValue(forKey: "protocolOverride")
        oldModels[0].removeValue(forKey: "jsonMode")
        raw["models"] = oldModels
        let oldData = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(ImpressAIRegistry.self, from: oldData)
        try decoded.validate()
        XCTAssertEqual(decoded.connections[0].credentialID, connection.credentialID)
        XCTAssertEqual(decoded.connections[0].effectiveAuthentication, .bearer)
        XCTAssertEqual(decoded.models[0].protocolOverride, nil)
        XCTAssertEqual(decoded.models[0].jsonMode, nil)
        XCTAssertEqual(try decoded.resolve(.questionGeneration).model.identifier, "model-A")
    }

    func testJSONModesAreIsolatedAcrossModelProfiles() throws {
        let gateway = ImpressAIConnection(title: "OpenCode Go", provider: .openCode,
             apiProtocol: .chatCompletions, baseURL: safeURL, credentialID: UUID())
        let a = ImpressAIModel(connectionID: gateway.id, identifier: "model-A",
                               jsonVerified: true, jsonMode: .native)
        let b = ImpressAIModel(connectionID: gateway.id, identifier: "model-B",
                               jsonVerified: true, jsonMode: .promptOnly)
        let config = try ImpressAIRegistry(connections: [gateway], models: [a,b],
                 routes: [.init(task: .questionGeneration, primaryModelID: a.id),
                          .init(task: .conversation, primaryModelID: b.id)])
        XCTAssertEqual(try config.resolve(.questionGeneration).model.jsonMode, .native)
        XCTAssertEqual(try config.resolve(.conversation).model.jsonMode, .promptOnly)
    }
}


extension ImpressAIContractsTests {
    func testChatCompletionAcceptsTextAndMultiblockContent() throws {
        let standard: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "  Hello.  "]]]
        ]
        XCTAssertEqual(try ImpressAIChatResponseParser.chatCompletionText(standard), "Hello.")
        let parts: [String: Any] = [
            "choices": [["message": ["content": [
                ["type": "text", "text": "First "],
                ["type": "text", "text": ["value": "second"]],
                ["type": "refusal", "refusal": "unrelated"]
            ]]]]
        ]
        XCTAssertEqual(try ImpressAIChatResponseParser.chatCompletionText(parts),
                       "First second")
    }

    func testChatCompletionRejectsReasoningWithoutVisibleAnswer() throws {
        let noVisible: [String: Any] = [
            "choices": [["message": ["content": NSNull(),
                                      "reasoning_content": "private thinking"]]]
        ]
        XCTAssertThrowsError(try ImpressAIChatResponseParser.chatCompletionText(noVisible))
        XCTAssertThrowsError(try ImpressAIChatResponseParser.chatCompletionText([
            "choices": [["message": ["content": "   "]]]
        ]))
        XCTAssertThrowsError(try ImpressAIChatResponseParser.chatCompletionText([
            "choices": []
        ]))
    }
}

// Free-only means exact documented OpenCode model IDs and endpoints; no
// paid model can be substituted by changing a label or using another gateway.
extension ImpressAIContractsTests {
    func testOpenCodeFreeQAPresetIsAnonymousAndUsesOfficialPaths() throws {
        let connection = ImpressAIOpenCodeFreeQA.connection()
        XCTAssertEqual(connection.provider, .openCode)
        XCTAssertEqual(connection.baseURL.absoluteString, "https://opencode.ai/inference")
        XCTAssertEqual(connection.effectiveAuthentication, .noAuthentication)
        XCTAssertNil(connection.credentialID)
        XCTAssertEqual(connection.effectiveEndpoints.modelsPath, "v1/models")
        XCTAssertEqual(connection.effectiveEndpoints.chatPath, "openai/v1/chat/completions")
        let models = ImpressAIOpenCodeFreeQA.models(for: connection.id)
        XCTAssertEqual(models.map(\.identifier), [
            "mimo-v2.6-flash-free", "longcat-2.5-preview-free",
            "nemotron-3.5-lightning-free", "space-bunny-free"
        ])
        XCTAssertEqual(ImpressAIOpenCodeFreeQA.modelIDs.count, 4)
        XCTAssertTrue(models.allSatisfy { $0.jsonMode == .promptOnly })
        try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: connection, model: models[0]))
        XCTAssertNoThrow(try ImpressAIRegistry(connections: [connection], models: models))
    }

    func testOpenCodeFreeQARejectsPaidOrUnapprovedIdentifiers() throws {
        let connection = ImpressAIOpenCodeFreeQA.connection()
        for id in ["glm-5.3-flash", "deepseek-v4.1-flash",
                   "gpt-6-sol", "glm-5.3-flash-free", "other-model-free", ""] {
            let model = ImpressAIModel(connectionID: connection.id, identifier: id)
            XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
                ImpressAIResolvedRoute(connection: connection, model: model)))
            XCTAssertFalse(ImpressAIOpenCodeFreeQA.allowedForCatalog(id))
        }
    }

    func testOpenCodeFreeQARejectsRedirectGatewayAndPaidProtocol() throws {
        let original = ImpressAIOpenCodeFreeQA.connection()
        let model = ImpressAIOpenCodeFreeQA.models(for: original.id)[0]
        var wrongHost = original
        wrongHost.baseURL = URL(string: "https://not-opencode.example/inference")!
        XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: wrongHost, model: model)))
        var wrongPath = original
        wrongPath.endpoints = .init(modelsPath: "v1/models",
             chatPath: "other/v1/chat/completions")
        XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: wrongPath, model: model)))
        var wrongWire = model
        wrongWire.protocolOverride = .responses
        XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: original, model: wrongWire)))
        var wrongAuth = original
        wrongAuth.authentication = .customHeader
        wrongAuth.customHeaderName = "X-Key"
        wrongAuth.credentialID = UUID()
        XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: wrongAuth, model: model)))
    }

    func testOpenCodeFreeQAAllowsExplicitUserKeyButOnlyFreeModels() throws {
        var connection = ImpressAIOpenCodeFreeQA.connection()
        connection.authentication = .bearer
        connection.credentialID = UUID()
        let model = ImpressAIOpenCodeFreeQA.models(for: connection.id)[0]
        XCTAssertNoThrow(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: connection, model: model)))
        var missingCredential = connection
        missingCredential.credentialID = nil
        XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: missingCredential, model: model)))
        let paidModel = ImpressAIModel(
            connectionID: connection.id, identifier: "glm-5.3-flash")
        XCTAssertThrowsError(try ImpressAIOpenCodeFreeQA.validate(
            ImpressAIResolvedRoute(connection: connection, model: paidModel)))
    }

    func testOpenCodeFreeQARequiresJSONProbeBeforeNoteGeneration() throws {
        let c = ImpressAIOpenCodeFreeQA.connection()
        let models = ImpressAIOpenCodeFreeQA.models(for: c.id)
        let routes: [ImpressAIRoute] = [
            .init(task: .conversation, primaryModelID: models[0].id),
            .init(task: .questionGeneration, primaryModelID: models[0].id)
        ]
        let registry = try ImpressAIRegistry(connections: [c], models: models, routes: routes)
        XCTAssertNoThrow(try registry.resolve(.conversation))
        XCTAssertThrowsError(try registry.resolve(.questionGeneration))
        var verified = models
        verified[0].jsonVerified = true
        let verifiedRegistry = try ImpressAIRegistry(connections: [c], models: verified,
                                                     routes: routes)
        XCTAssertNoThrow(try verifiedRegistry.resolve(.questionGeneration))
    }
}

extension ImpressAIContractsTests {
    func testGLMNormalProviderRoutesChatAndVerifiedQuestionGeneration() throws {
        let connection = ImpressAIConnection(title: "GLM China", provider: .zhipu,
            apiProtocol: .chatCompletions,
            baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!,
            credentialID: UUID())
        let model = ImpressAIModel(connectionID: connection.id, identifier: "glm-4.5-flash",
                                   jsonVerified: true)
        var reg = try ImpressAIRegistry(connections: [connection], models: [model])
        XCTAssertEqual(reg.selectableModels(for: .conversation).map(\.id), [model.id])
        try reg.setDefaultModel(model.id, for: .conversation)
        try reg.setDefaultModel(model.id, for: .questionGeneration)
        XCTAssertEqual(try reg.resolve(.conversation).connection.provider, .zhipu)
        XCTAssertEqual(try reg.resolve(.questionGeneration).model.identifier, "glm-4.5-flash")
        XCTAssertNoThrow(try ImpressAIRequestPolicy.validate(
            ImpressAIResolvedRoute(connection: connection, model: model)))
    }

    func testQAIsExplicitAndNeverBlocksGenericOpenCodeOrZAI() throws {
        let qa = ImpressAIOpenCodeFreeQA.connection()
        XCTAssertEqual(qa.freeQAOnly, true)
        let unauthorized = ImpressAIModel(connectionID: qa.id, identifier: "arbitrary-paid-model")
        XCTAssertThrowsError(try ImpressAIRequestPolicy.validate(
            ImpressAIResolvedRoute(connection: qa, model: unauthorized)))

        let independent = ImpressAIConnection(title: "OpenCode Console",
            provider: .openCode, apiProtocol: .chatCompletions,
            baseURL: ImpressAIOpenCodeFreeQA.baseURL, credentialID: UUID(),
            endpoints: ImpressAIOpenCodeFreeQA.endpoints)
        XCTAssertFalse(ImpressAIOpenCodeFreeQA.isQAProfile(independent))
        XCTAssertNoThrow(try ImpressAIRequestPolicy.validate(
            ImpressAIResolvedRoute(connection: independent,
                model: ImpressAIModel(connectionID: independent.id, identifier: "custom-user-model"))))

        let international = ImpressAIConnection(title: "Z.AI", provider: .zhipu,
            apiProtocol: .chatCompletions,
            baseURL: URL(string: "https://api.z.ai/api/paas/v4")!, credentialID: UUID())
        XCTAssertNoThrow(try ImpressAIRequestPolicy.validate(
            ImpressAIResolvedRoute(connection: international,
                model: ImpressAIModel(connectionID: international.id, identifier: "glm-4.7"))))
    }

    func testLegacyFreeQAProfileDecodesWithoutExplicitFlagAndCannotEscapeViaRename() throws {
        let qa = ImpressAIOpenCodeFreeQA.connection()
        let encoded = try JSONEncoder().encode(qa)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "freeQAOnly")
        let previous = try JSONDecoder().decode(ImpressAIConnection.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(ImpressAIOpenCodeFreeQA.isQAProfile(previous))
        var renamed = qa
        renamed.title = "My QA alias"
        XCTAssertTrue(ImpressAIOpenCodeFreeQA.isQAProfile(renamed))
        XCTAssertThrowsError(try ImpressAIRequestPolicy.validate(
            ImpressAIResolvedRoute(connection: renamed,
                model: ImpressAIModel(connectionID: renamed.id, identifier: "not-on-free-list"))))
    }

    func testDeleteAllProvidersAndCascadeOrphansWhileRetainingValidPrimary() throws {
        let a = ImpressAIConnection(title: "GLM", provider: .zhipu,
            apiProtocol: .chatCompletions, baseURL: safeURL, credentialID: UUID())
        let b = ImpressAIConnection(title: "Another provider", provider: .custom,
            apiProtocol: .chatCompletions, baseURL: safeURL, credentialID: UUID())
        let m1 = ImpressAIModel(connectionID: a.id, identifier: "glm")
        let m2 = ImpressAIModel(connectionID: b.id, identifier: "another")
        var reg = try ImpressAIRegistry(connections: [a,b], models: [m1,m2],
            routes: [
                ImpressAIRoute(task: .conversation, primaryModelID: m1.id,
                    fallbackModelID: m2.id, crossProviderAuthorized: true),
                ImpressAIRoute(task: .questionGeneration, primaryModelID: m2.id)
            ])
        try reg.removeConnection(b.id)
        XCTAssertEqual(reg.routes.count, 1)
        XCTAssertEqual(reg.routes.first?.primaryModelID, m1.id)
        XCTAssertNil(reg.routes.first?.fallbackModelID)
        try reg.removeConnection(a.id)
        XCTAssertTrue(reg.connections.isEmpty)
        XCTAssertTrue(reg.models.isEmpty)
        XCTAssertTrue(reg.routes.isEmpty)
        try reg.removeAllConnections()
        XCTAssertNoThrow(try reg.validate())
    }

    func testRemovingModelRemovesOnlyItsDependentRoute() throws {
        let c = ImpressAIConnection(title: "GLM", provider: .zhipu,
            apiProtocol: .chatCompletions, baseURL: safeURL, credentialID: UUID())
        let a = ImpressAIModel(connectionID: c.id, identifier: "glm-A")
        let b = ImpressAIModel(connectionID: c.id, identifier: "glm-B")
        var reg = try ImpressAIRegistry(connections: [c], models: [a,b],
            routes: [.init(task: .conversation, primaryModelID: a.id),
                     .init(task: .questionGeneration, primaryModelID: b.id)])
        try reg.removeModel(a.id)
        XCTAssertEqual(reg.routes.map(\.task), [.questionGeneration])
        XCTAssertNoThrow(try reg.validate())
    }

    func testUnverifiedGLMIsVisibleButPrivateNoteGenerationStillBlocked() throws {
        let c = ImpressAIConnection(title: "GLM", provider: .zhipu,
            apiProtocol: .chatCompletions, baseURL: safeURL, credentialID: UUID())
        let model = ImpressAIModel(connectionID: c.id, identifier: "glm-4.5-flash")
        var reg = try ImpressAIRegistry(connections: [c], models: [model])
        XCTAssertEqual(reg.selectableModels(for: .questionGeneration).count, 1)
        try reg.setDefaultModel(model.id, for: .questionGeneration)
        XCTAssertThrowsError(try reg.resolve(.questionGeneration)) {
            XCTAssertEqual($0 as? ImpressAIContractError, .unverifiedModel)
        }
        XCTAssertNoThrow(try reg.setDefaultModel(model.id, for: .conversation))
    }
}
