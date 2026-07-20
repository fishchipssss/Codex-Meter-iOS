import Foundation
import Security
import CodexMeterCore

enum AccountSource: Equatable, Sendable {
    case direct(accountId: String)
    case proxy(profileId: UUID)

    var stateID: String {
        switch self {
        case let .direct(id): "direct:\(id)"
        case let .proxy(id): "proxy:\(id.uuidString.lowercased())"
        }
    }

    var sourceLabel: String? {
        switch self { case .direct: nil; case .proxy: "CLI PROXY" }
    }
}

struct ProxyProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var baseURL: URL
    var email: String
    var planType: String
    let createdAt: Date
    var lastSuccessfulRefresh: Date?
}

enum ProxyProfileStore {
    private static let key = "codex-cli-proxy-profiles-v1"

    static func loadAll() -> [ProxyProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ProxyProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [ProxyProfile]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(profiles), forKey: key)
    }

    static func upsert(_ profile: ProxyProfile) throws {
        var profiles = loadAll()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try save(profiles)
    }

    static func remove(_ id: UUID) throws {
        try save(loadAll().filter { $0.id != id })
    }

    static func removeAll() { UserDefaults.standard.removeObject(forKey: key) }
}

enum ProxyCredentialStore {
    private static let service = "com.picklemike.codexmeter.proxy"

    static func save(token: String, id: UUID) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString.lowercased()
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MeterError.message("Could not save the proxy token in Keychain (\(status)).") }
    }

    static func load(id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString.lowercased(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString.lowercased()
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func removeAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}

private struct ProxyErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let message: String; let retryable: Bool }
    let error: Detail
}

private struct ProxyResetResponse: Decodable { let outcome: String }

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

actor ProxyAPI {
    static let shared = ProxyAPI()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func test(_ setup: ProxySetupCode) async throws -> ParsedProxySnapshot {
        _ = try await request(path: "v1/health", method: "GET", baseURL: setup.baseURL, token: setup.token)
        let data = try await request(path: "v1/snapshot", method: "GET", baseURL: setup.baseURL, token: setup.token)
        let parsed = try ProxySnapshotParser.parse(data)
        guard parsed.proxyId == setup.id else { throw MeterError.message("The proxy identifier did not match the setup code.") }
        return parsed
    }

    func refresh(_ profile: ProxyProfile) async throws -> ParsedProxySnapshot {
        guard let token = ProxyCredentialStore.load(id: profile.id) else { throw MeterError.message("The proxy access token is missing.") }
        let data = try await request(path: "v1/snapshot", method: "GET", baseURL: profile.baseURL, token: token)
        let parsed = try ProxySnapshotParser.parse(data)
        guard parsed.proxyId == profile.id else { throw MeterError.message("The connected proxy returned a different identifier.") }
        return parsed
    }

    func consumeReset(_ profile: ProxyProfile, creditId: String?) async throws -> String {
        guard let token = ProxyCredentialStore.load(id: profile.id) else { throw MeterError.message("The proxy access token is missing.") }
        let payload: [String: Any] = [
            "idempotency_key": UUID().uuidString.lowercased(),
            "credit_id": creditId ?? NSNull()
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "v1/reset", method: "POST", baseURL: profile.baseURL, token: token, body: body)
        return try JSONDecoder().decode(ProxyResetResponse.self, from: data).outcome
    }

    private func request(path: String, method: String, baseURL: URL, token: String, body: Data? = nil) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Codex-Meter-Protocol")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeterError.message("The proxy returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ProxyErrorEnvelope.self, from: data) {
                throw MeterError.message(envelope.error.message)
            }
            throw MeterError.message("The proxy request failed (HTTP \(http.statusCode)).")
        }
        return data
    }
}
