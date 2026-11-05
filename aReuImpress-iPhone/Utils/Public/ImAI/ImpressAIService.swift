import Foundation
import Security
import ImpressReviewCore

// New AI architecture. This is not the removed legacy Chat/LLM implementation.
// The UI manages provider-owned credentials; no API key value is Codable or logged.
enum ImpressAIServiceError: LocalizedError {
    case configuration, credential, invalidURL, unauthorized, forbidden, status(Int), response, tooLarge, emptyModelList
    case freeModelOnly, rateLimited, keychainOSStatus(Int)
    case unsupportedImageInput
    var errorDescription: String? {
        switch self {
        case .configuration: return V3L("请先在设置中配置并测试 AI 出题模型。")
        case .freeModelOnly: return V3L("本 QA 版只允许 OpenCode 官方免费模型；推荐添加「OpenCode 免费模型（测试）」，不需要密钥。使用 Keychain 密钥时也只允许相同的免费型号。")
        case .credential: return V3L("API Key 不可用，请重新保存密钥。")
        case .keychainOSStatus(let code): return V3L("Keychain 无法访问，OSStatus") + " \(code)"
        case .invalidURL: return V3L("API 地址不安全或不正确。")
        case .unauthorized: return V3L("API 授权失败（401），请检查密钥。")
        case .forbidden: return V3L("OpenCode 返回 HTTP 403：可能是当前网络、账户权限或访问限制。确认免费定价后，再使用设备 Keychain 中的新 Key 重试。")
        case .rateLimited: return V3L("OpenCode 返回 HTTP 429：免费模型暂时受限，请稍后重试；不会自动切换收费模型。")
        case .status(let code): return "AI API 请求失败（HTTP \(code)），原始数据未改变。"
        case .response: return V3L("模型没有返回可用文本，或回复格式不兼容。请检查模型及协议。")
        case .tooLarge: return V3L("请求或响应超出安全长度限制。")
        case .unsupportedImageInput:
            return V3L("当前模型/协议未确认支持图片，或图片不符合安全格式；图片未发送。")
        case .emptyModelList: return V3L("服务商未返回模型列表，请手动输入模型 ID。")
        }
    }
}

enum ImpressAIKeychain {
    private static let service = "com.areu2.iphone.impress.ai.v1"

    static func write(_ value: String, id: UUID) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty && token.utf8.count < 8_192 else { throw ImpressAIServiceError.credential }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw ImpressAIServiceError.keychainOSStatus(Int(status))
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw ImpressAIServiceError.keychainOSStatus(Int(added))
        }
    }

    static func read(id: UUID?) throws -> String {
        guard let id else { throw ImpressAIServiceError.credential }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw ImpressAIServiceError.keychainOSStatus(Int(status))
        }
        guard let bytes = item as? Data,
              let secret = String(data: bytes, encoding: .utf8), !secret.isEmpty else {
            throw ImpressAIServiceError.credential
        }
        return secret
    }

    static func delete(id: UUID?) {
        guard let id else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class ImpressAIConfigStore {
    static let shared = ImpressAIConfigStore()
    private let url: URL
    private(set) var registry: ImpressAIRegistry

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImpressV3", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("AIConnections-v1.json")
        if let data = try? Data(contentsOf: url),
           let record = try? JSONDecoder().decode(ImpressAIRegistry.self, from: data),
           (try? record.validate()) != nil {
            registry = record
        } else {
            registry = try! ImpressAIRegistry()
        }
    }

    func replace(_ value: ImpressAIRegistry) throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        registry = value
    }

    func update(_ operation: (inout ImpressAIRegistry) throws -> Void) throws {
        var next = registry
        try operation(&next)
        try replace(next)
    }

    /// Persist the referential cleanup before deleting the credential. A key
    /// still referenced by another connection is never removed.
    func deleteConnection(id: UUID) throws {
        guard let connection = registry.connections.first(where: { $0.id == id }) else {
            throw ImpressAIServiceError.configuration
        }
        try update { try $0.removeConnection(id) }
        if let key = connection.credentialID,
           !registry.connections.contains(where: { $0.credentialID == key }) {
            ImpressAIKeychain.delete(id: key)
        }
    }

    func deleteAllConnections() throws {
        let keys = Set(registry.connections.compactMap(\.credentialID))
        try update { try $0.removeAllConnections() }
        for key in keys {
            ImpressAIKeychain.delete(id: key)
        }
    }

    func clearCredential(connectionID: UUID) throws {
        guard let c = registry.connections.first(where: { $0.id == connectionID })
        else { throw ImpressAIServiceError.configuration }
        try update { reg in
            guard let i = reg.connections.firstIndex(where: { $0.id == connectionID })
            else { throw ImpressAIServiceError.configuration }
            reg.connections[i].credentialID = nil
            if ImpressAIOpenCodeFreeQA.isQAProfile(c) {
                reg.connections[i].freeQAOnly = true
                reg.connections[i].authentication = .noAuthentication
            }
            for m in reg.models.indices where reg.models[m].connectionID == connectionID {
                reg.models[m].jsonVerified = false
                reg.models[m].toolsVerified = false
            }
        }
        if let old = c.credentialID,
           !registry.connections.contains(where: { $0.credentialID == old }) {
            ImpressAIKeychain.delete(id: old)
        }
    }
}

// Disable automatic redirection, which could otherwise forward an Authorization
// header or private note content to a new, unapproved endpoint.
private final class ImpressAINoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Ephemeral conversation turns. No conversation is persisted to app backups
/// or turned into knowledge automatically.
enum ImpressAIChatRole: String, Sendable {
    case user, assistant
}

struct ImpressAIChatTurn: Sendable {
    let role: ImpressAIChatRole
    let text: String
}

/// Ephemeral JPEG only: never persisted, backed up, or silently retried.
struct ImpressAIImagePayload: Sendable {
    let jpeg: Data
    let displayName: String
}

actor ImpressAIHTTPClient {
    static let shared = ImpressAIHTTPClient()
    private let session: URLSession

    init(session: URLSession? = nil) {
        // Dependency injection is available only to native XCTest. Production
        // uses a fresh ephemeral session with redirects always disabled.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 50
            config.timeoutIntervalForResource = 90
            config.httpMaximumConnectionsPerHost = 2
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config,
                                      delegate: ImpressAINoRedirect(), delegateQueue: nil)
        }
    }

    private func endpoint(_ connection: ImpressAIConnection, route: String) throws -> URL {
        guard connection.baseURL.scheme?.lowercased() == "https",
              connection.baseURL.user == nil, connection.baseURL.password == nil,
              connection.baseURL.query == nil, connection.baseURL.fragment == nil,
              (connection.baseURL.port == nil || connection.baseURL.port == 443) else {
            throw ImpressAIServiceError.invalidURL
        }
        return connection.baseURL.appendingPathComponent(route)
    }

    private func request(_ connection: ImpressAIConnection, path: String,
                         method: String, wireProtocol: ImpressAIProtocol,
                         body: [String: Any]? = nil,
                         maxJSONBytes: Int = 90_000) throws -> URLRequest {
        try connection.effectiveEndpoints.validate()
        guard wireProtocol == .geminiGenerateContent ||
              ImpressAIEndpointPaths.safePath(path) else {
            throw ImpressAIServiceError.invalidURL
        }
        var result = URLRequest(url: try endpoint(connection, route: path))
        result.httpMethod = method
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        // Auth is configured per connection, independently of each model's
        // payload protocol. This supports Bearer-auth Messages gateways.
        let auth = connection.effectiveAuthentication
        if auth != .noAuthentication {
            let secret = try ImpressAIKeychain.read(id: connection.credentialID)
            switch auth {
            case .bearer:
                result.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
            case .rawAuthorization:
                result.setValue(secret, forHTTPHeaderField: "Authorization")
            case .apiKeyHeader:
                result.setValue(secret, forHTTPHeaderField: "x-api-key")
            case .googleAPIKeyHeader:
                result.setValue(secret, forHTTPHeaderField: "x-goog-api-key")
            case .customHeader:
                guard ImpressAIRegistry.safeCustomHeader(connection.customHeaderName ?? "") else {
                    throw ImpressAIServiceError.invalidURL
                }
                result.setValue(secret, forHTTPHeaderField: connection.customHeaderName!)
            case .noAuthentication:
                break
            }
        }
        if wireProtocol == .anthropicMessages {
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let body {
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= maxJSONBytes else { throw ImpressAIServiceError.tooLarge }
            result.httpBody = data
            result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return result
    }

    private func executeDetailed(_ request: URLRequest) async throws
        -> (body: [String: Any], statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImpressAIServiceError.response }
        if http.statusCode == 401 { throw ImpressAIServiceError.unauthorized }
        if http.statusCode == 403 { throw ImpressAIServiceError.forbidden }
        if http.statusCode == 429 { throw ImpressAIServiceError.rateLimited }
        guard (200...299).contains(http.statusCode) else {
            throw ImpressAIServiceError.status(http.statusCode)
        }
        guard data.count < 1_000_000,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImpressAIServiceError.response
        }
        return (obj, http.statusCode)
    }

    private func execute(_ request: URLRequest) async throws -> [String: Any] {
        let result = try await executeDetailed(request)
        return result.body
    }

    /// Official Console service-account probe for the same Keychain credential
    /// used by inference. Inference-only keys may GET /api/v2/config.
    /// Never render, log, persist or print the private workspace JSON or key.
    func probeOpenCodeServiceAccount(connection: ImpressAIConnection) async throws -> Int {
        guard connection.provider == .openCode,
              connection.baseURL == ImpressAIOpenCodeFreeQA.baseURL,
              connection.effectiveAuthentication == .bearer,
              connection.credentialID != nil,
              let url = URL(string: "https://opencode.ai/console/api/v2/config") else {
            throw ImpressAIServiceError.configuration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let secret = try ImpressAIKeychain.read(id: connection.credentialID)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImpressAIServiceError.response
        }
        if http.statusCode == 401 { throw ImpressAIServiceError.unauthorized }
        if http.statusCode == 403 { throw ImpressAIServiceError.forbidden }
        if http.statusCode == 429 { throw ImpressAIServiceError.rateLimited }
        guard (200...299).contains(http.statusCode) else {
            throw ImpressAIServiceError.status(http.statusCode)
        }
        return http.statusCode
    }

    // No inference of models' structured-output capability from this listing.
    func listModels(connection: ImpressAIConnection) async throws -> [String] {
        let path = connection.effectiveEndpoints.modelsPath
        guard !path.isEmpty else { throw ImpressAIServiceError.emptyModelList }
        let obj = try await execute(request(connection, path: path, method: "GET",
                                            wireProtocol: connection.apiProtocol))
        let entries = obj["data"] as? [[String: Any]] ??
                      obj["models"] as? [[String: Any]] ?? []
        let values = entries.compactMap { item -> String? in
            let raw = item["id"] as? String ?? item["name"] as? String ?? ""
            let name = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            return name.isEmpty ? nil : name
        }
        let cleaned = Array(Set(values)).sorted()
        // OpenCode's model catalog includes paid models. Neither a
        // Keychain-backed nor anonymous QA connection may present them.
        let filtered = ImpressAIOpenCodeFreeQA.isQAProfile(connection)
            ? cleaned.filter(ImpressAIOpenCodeFreeQA.allowedForCatalog)
            : cleaned
        guard !filtered.isEmpty else { throw ImpressAIServiceError.emptyModelList }
        return Array(filtered.prefix(300))
    }

    func complete(route: ImpressAIResolvedRoute, system: String,
                  user: String) async throws -> String {
        try await completeDetailed(route: route, system: system, user: user).text
    }

    /// Expose a redacted HTTP status without persisting provider request or reply.
    func completeDetailed(route: ImpressAIResolvedRoute, system: String,
                          user: String) async throws -> (text: String, statusCode: Int) {
        // Reject paid model IDs before sending any request, whether anonymous
        // or explicitly authenticated from device Keychain.
        // The QA allowlist belongs only to the opt-in QA profile.
        // GLM, DeepSeek, custom and user-owned providers use their real protocol.
        try ImpressAIRequestPolicy.validate(route)
        let c = route.connection
        let model = route.model.identifier
        guard system.utf8.count + user.utf8.count <= 65_000 else { throw ImpressAIServiceError.tooLarge }
        var payload: [String: Any]
        let path: String
        let wire = route.effectiveProtocol
        switch wire {
        case .responses:
            path = c.effectiveEndpoints.responsesPath
            payload = ["model": model, "instructions": system, "input": user,
                       "store": false, "max_output_tokens": 2200]
        case .chatCompletions:
            path = c.effectiveEndpoints.chatPath
            payload = ["model": model, "stream": false,
                       "messages": [
                           ["role": "system", "content": system],
                           ["role": "user", "content": user]
                       ]]
            if route.model.jsonMode != .promptOnly {
                payload["response_format"] = ["type": "json_object"]
            }
        case .anthropicMessages:
            path = c.effectiveEndpoints.messagesPath
            payload = ["model": model, "max_tokens": 2200,
                       "system": system,
                       "messages": [["role": "user", "content": user]]]
        case .geminiGenerateContent:
            let characters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            let encoded = model.addingPercentEncoding(withAllowedCharacters: characters) ?? model
            path = "models/" + encoded + ":generateContent"
            payload = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": route.model.jsonMode == .promptOnly ? [:] :
                                    ["responseMimeType": "application/json"]
            ]
        }
        let detailed = try await executeDetailed(request(c, path: path,
                               method: "POST", wireProtocol: wire, body: payload))
        let json = detailed.body
        var answer: String?
        switch wire {
        case .responses:
            if let output = json["output"] as? [[String: Any]] {
                let parts = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                answer = parts.filter { ($0["type"] as? String) == "output_text" }
                    .compactMap { $0["text"] as? String }.joined()
            }
            if answer?.isEmpty != false { answer = json["output_text"] as? String }
        case .chatCompletions:
            answer = try? ImpressAIChatResponseParser.chatCompletionText(json)
        case .anthropicMessages:
            let content = json["content"] as? [[String: Any]] ?? []
            answer = content.filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.joined()
        case .geminiGenerateContent:
            let candidates = json["candidates"] as? [[String: Any]] ?? []
            let contents = candidates.first?["content"] as? [String: Any]
            answer = (contents?["parts"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined()
        }
        guard let text = answer, !text.isEmpty, text.utf8.count < 70_000 else {
            throw ImpressAIServiceError.response
        }
        return (text, detailed.statusCode)
    }

    /// Actual native text conversation, NOT the structured JSON question API.
    /// Only an explicit Send tap reaches this method. No Vault read/write tools.
    func converse(route: ImpressAIResolvedRoute, system: String,
                  turns: [ImpressAIChatTurn]) async throws -> String {
        let result = try await converseDetailed(route: route, system: system, turns: turns)
        return result.text
    }

    /// The actual HTTP status is surfaced only for an explicit, harmless probe.
    func converseDetailed(route: ImpressAIResolvedRoute, system: String,
                         turns: [ImpressAIChatTurn]) async throws
        -> (text: String, statusCode: Int) {
        guard !turns.isEmpty, turns.last?.role == .user, turns.count <= 20,
              system.utf8.count <= 4_000,
              turns.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 && $0.text.utf8.count <= 12_000 }),
              turns.reduce(0, { $0 + $1.text.utf8.count }) <= 55_000 else {
            throw ImpressAIServiceError.tooLarge
        }
        // The QA allowlist belongs only to the opt-in QA profile.
        // GLM, DeepSeek, custom and user-owned providers use their real protocol.
        try ImpressAIRequestPolicy.validate(route)
        let connection = route.connection
        let model = route.model.identifier
        let wire = route.effectiveProtocol
        let endpointPath: String
        let payload: [String: Any]
        switch wire {
        case .responses:
            endpointPath = connection.effectiveEndpoints.responsesPath
            payload = ["model": model, "instructions": system,
                       "input": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
                       "store": false, "max_output_tokens": 1400]
        case .chatCompletions:
            endpointPath = connection.effectiveEndpoints.chatPath
            let messages: [[String: String]] = [["role": "system", "content": system]] +
                turns.map { ["role": $0.role.rawValue, "content": $0.text] }
            payload = ["model": model, "messages": messages, "stream": false]
        case .anthropicMessages:
            endpointPath = connection.effectiveEndpoints.messagesPath
            payload = ["model": model, "system": system, "max_tokens": 1400,
                       "messages": turns.map {
                           ["role": $0.role.rawValue, "content": $0.text]
                       }]
        case .geminiGenerateContent:
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            let safeModel = model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model
            endpointPath = "models/" + safeModel + ":generateContent"
            payload = ["systemInstruction": ["parts": [["text": system]]],
                       "contents": turns.map { item in
                           ["role": item.role == .assistant ? "model" : "user",
                            "parts": [["text": item.text]]]
                       }]
        }
        let response = try await executeDetailed(request(connection, path: endpointPath,
                            method: "POST", wireProtocol: wire, body: payload))
        let body = response.body
        let text: String?
        switch wire {
        case .responses:
            let items = body["output"] as? [[String: Any]] ?? []
            let parts = items.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            let combined = parts.filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
            text = combined.isEmpty ? body["output_text"] as? String : combined
        case .chatCompletions:
            text = try? ImpressAIChatResponseParser.chatCompletionText(body)
        case .anthropicMessages:
            let parts = body["content"] as? [[String: Any]] ?? []
            text = parts.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
        case .geminiGenerateContent:
            let responses = body["candidates"] as? [[String: Any]] ?? []
            let content = responses.first?["content"] as? [String: Any]
            text = (content?["parts"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined()
        }
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= 65_000 else {
            throw ImpressAIServiceError.response
        }
        return (value, response.statusCode)
    }

    /// Validated real SSE transport. Never retries on a different provider,
    /// silently upgrades paid models, or marks a lost socket as completed.
    /// The renderer can consume this stream without changing WCDB schema.
    /// All automated tests inject a zero-network URLProtocol fixture.
    /// One validated wire request per explicit Send. Private in production;
    /// the Debug-only projection allows zero-network payload assertions.
    private func makeConverseStreamRequest(
        route: ImpressAIResolvedRoute, system: String, turns: [ImpressAIChatTurn],
        images: [ImpressAIImagePayload] = []
    ) throws -> (URLRequest, ImpressChatPOCProviderProtocol) {
        guard !turns.isEmpty, turns.last?.role == .user, turns.count <= 20,
              system.utf8.count <= 4_000,
              turns.enumerated().allSatisfy({ index, turn in
                  // Only a final user turn with real approved JPEGs may omit text.
                  (index == turns.count - 1 && !images.isEmpty ||
                   !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
                  turn.text.utf8.count <= 12_000
              }),
              turns.reduce(0, { $0 + $1.text.utf8.count }) <= 55_000 else {
            throw ImpressAIServiceError.tooLarge
        }
        try ImpressAIRequestPolicy.validate(route)
        let connection = route.connection
        let wire = route.effectiveProtocol
        let model = route.model.identifier
        // No model-name heuristic. Explicitly approved image bytes only.
        // The QA free lane cannot be silently promoted to a vision endpoint.
        if !images.isEmpty {
            guard route.model.supportsImageInput == true,
                  !ImpressAIOpenCodeFreeQA.isQAProfile(connection),
                  images.count <= 3,
                  images.reduce(0, { $0 + $1.jpeg.count }) <= 1_200_000,
                  images.allSatisfy({
                      $0.jpeg.count >= 5 && $0.jpeg.count <= 400_000 &&
                      $0.jpeg.starts(with: [0xFF, 0xD8, 0xFF]) &&
                      $0.jpeg.suffix(2).elementsEqual([0xFF, 0xD9])
                  }) else {
                throw ImpressAIServiceError.unsupportedImageInput
            }
        }
        let encodedImages = images.map { $0.jpeg.base64EncodedString() }
        let endpointPath: String
        let payload: [String: Any]
        let protocolID: ImpressChatPOCProviderProtocol

        switch wire {
        case .responses:
            endpointPath = connection.effectiveEndpoints.responsesPath
            protocolID = .openAIResponses
            let input: [[String: Any]] = turns.enumerated().map { index, turn in
                guard index == turns.count - 1, !images.isEmpty else {
                    return ["role": turn.role.rawValue, "content": turn.text]
                }
                var parts: [[String: Any]] = turn.text.isEmpty ? [] : [
                    ["type": "input_text", "text": turn.text]
                ]
                parts += encodedImages.map { ["type": "input_image",
                    "image_url": "data:image/jpeg;base64," + $0] }
                return ["role": turn.role.rawValue, "content": parts]
            }
            payload = ["model": model, "instructions": system,
                       "input": input, "store": false, "stream": true,
                       "max_output_tokens": 1400]
        case .chatCompletions:
            endpointPath = connection.effectiveEndpoints.chatPath
            protocolID = .openAIChat
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            messages += turns.enumerated().map { index, turn in
                guard index == turns.count - 1, !images.isEmpty else {
                    return ["role": turn.role.rawValue, "content": turn.text]
                }
                var parts: [[String: Any]] = turn.text.isEmpty ? [] :
                    [["type": "text", "text": turn.text]]
                parts += encodedImages.map { ["type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64," + $0]] }
                return ["role": turn.role.rawValue, "content": parts]
            }
            payload = ["model": model, "messages": messages, "stream": true]
        case .anthropicMessages:
            endpointPath = connection.effectiveEndpoints.messagesPath
            protocolID = .anthropicMessages
            payload = ["model": model, "system": system, "max_tokens": 1400,
                       "stream": true,
                       "messages": turns.enumerated().map { index, turn
                           -> [String: Any] in
                           guard index == turns.count - 1, !images.isEmpty else {
                               return ["role": turn.role.rawValue, "content": turn.text]
                           }
                           var parts: [[String: Any]] = turn.text.isEmpty ? [] : [
                                ["type": "text", "text": turn.text]
                            ]
                           parts += encodedImages.map { ["type": "image",
                               "source": ["type": "base64", "media_type": "image/jpeg",
                                          "data": $0]] }
                           return ["role": turn.role.rawValue, "content": parts]
                       }]
        case .geminiGenerateContent:
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            let safeModel = model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model
            endpointPath = "models/" + safeModel + ":streamGenerateContent"
            protocolID = .geminiGenerateContent
            payload = ["systemInstruction": ["parts": [["text": system]]],
                       "contents": turns.enumerated().map { index, item
                           -> [String: Any] in
                           var parts: [[String: Any]] = item.text.isEmpty ? [] :
                                [["text": item.text]]
                           if index == turns.count - 1 {
                               parts += encodedImages.map {
                                   ["inlineData": ["mimeType": "image/jpeg",
                                                   "data": $0]]
                               }
                           }
                           return ["role": item.role == .assistant ? "model" : "user",
                                   "parts": parts]
                       }]
        }
        var wireRequest = try request(connection, path: endpointPath,
                                      method: "POST", wireProtocol: wire, body: payload,
                                      maxJSONBytes: images.isEmpty ? 90_000 : 2_200_000)
        if wire == .geminiGenerateContent {
            guard let url = wireRequest.url,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.queryItems == nil else {
                throw ImpressAIServiceError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            guard let target = components.url else { throw ImpressAIServiceError.invalidURL }
            wireRequest.url = target
        }
        wireRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        wireRequest.timeoutInterval = 90
        return (wireRequest, protocolID)
    }

    #if DEBUG
    func debugPreparedStreamRequest(route: ImpressAIResolvedRoute, system: String,
                                    turns: [ImpressAIChatTurn],
                                    images: [ImpressAIImagePayload] = []) throws -> URLRequest {
        try makeConverseStreamRequest(
            route: route, system: system, turns: turns, images: images).0
    }
    #endif

    func converseStream(route: ImpressAIResolvedRoute, system: String,
                        turns: [ImpressAIChatTurn],
                        images: [ImpressAIImagePayload] = []) async throws
        -> AsyncThrowingStream<ImpressChatPOCOutput, Error> {
        let (wireRequest, protocolID) = try makeConverseStreamRequest(
            route: route, system: system, turns: turns, images: images)
        let currentSession = session
        return AsyncThrowingStream { continuation in
            let transportTask = Task {
                do {
                    let (bytes, response) = try await currentSession.bytes(for: wireRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ImpressAIServiceError.response
                    }
                    switch http.statusCode {
                    case 401: throw ImpressAIServiceError.unauthorized
                    case 403: throw ImpressAIServiceError.forbidden
                    case 429: throw ImpressAIServiceError.rateLimited
                    case 200...299: break
                    default: throw ImpressAIServiceError.status(http.statusCode)
                    }
                    guard http.value(forHTTPHeaderField: "Content-Type")?
                        .lowercased().contains("text/event-stream") == true else {
                        throw ImpressAIServiceError.response
                    }
                    var decoder = ImpressChatPOCReplay(provider: protocolID)
                    var fragment = Data()
                    var visibleBytes = 0
                    var terminalReceived = false
                    func offer(_ output: ImpressChatPOCOutput) throws {
                        switch output {
                        case .delta(let text):
                            visibleBytes += text.utf8.count
                            guard visibleBytes <= 65_000 else {
                                throw ImpressAIServiceError.tooLarge
                            }
                            continuation.yield(output)
                        case .completed:
                            guard visibleBytes > 0 else {
                                throw ImpressAIServiceError.response
                            }
                            terminalReceived = true
                            continuation.yield(.completed)
                        case .failed:
                            throw ImpressAIServiceError.response
                        }
                    }
                    // A provider may keep its HTTP/SSE socket open after an
                    // authenticated terminal frame. Do not strand the Composer
                    // in "sending" waiting for a transport EOF that might never
                    // arrive. The normalizer, not a raw [DONE] string, decides
                    // whether a terminal is valid.
                    streamBytes: for try await byte in bytes {
                        try Task.checkCancellation()
                        fragment.append(byte)
                        if byte == 10 || fragment.count >= 2048 {
                            for output in try decoder.append(fragment) {
                                try offer(output)
                                if terminalReceived { break }
                            }
                            fragment.removeAll(keepingCapacity: true)
                            if terminalReceived { break streamBytes }
                        }
                    }
                    try Task.checkCancellation()
                    if !terminalReceived {
                        if !fragment.isEmpty {
                            for output in try decoder.append(fragment) { try offer(output) }
                        }
                        if !terminalReceived {
                            for output in try decoder.finish() { try offer(output) }
                        }
                    }
                    guard decoder.normalizer.isCompleted, visibleBytes > 0 else {
                        // Unexpected EOF is partial, never success or retry.
                        throw ImpressAIServiceError.response
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                transportTask.cancel()
            }
        }
    }

    /// Harmless connectivity + JSON probe. It is not a guarantee of factual correctness.
    func probeJSON(connection: ImpressAIConnection, model: ImpressAIModel) async throws -> Bool {
        let resolved = ImpressAIResolvedRoute(connection: connection, model: model)
        let output = try await complete(route: resolved,
              system: "Return a single valid JSON object and nothing else.",
              user: "Reply with exactly: {\"ok\":true}")
        guard let data = output.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return obj["ok"] as? Bool == true
    }
}
