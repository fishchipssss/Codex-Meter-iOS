import Foundation
import CodexMeterCore
import WidgetKit

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String? }
    let errorDescription: String?
    let error: Detail?
    let message: String?
    enum CodingKeys: String, CodingKey {
        case errorDescription = "error_description"
        case error, message
    }
}

enum AuthAPI {
    static func exchange(code: String, redirectURI: String, verifier: String) async throws -> AuthTokens {
        let body = formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": CodexConstants.clientID,
            "code_verifier": verifier
        ])
        return try await tokenRequest(body: body, contentType: "application/x-www-form-urlencoded", previous: nil)
    }

    static func refresh(_ previous: AuthTokens) async throws -> AuthTokens {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": previous.refreshToken,
            "client_id": CodexConstants.clientID
        ])
        return previous.mergingRefresh(try await tokenRequest(body: body, contentType: "application/json", previous: previous))
    }

    static func revoke(_ tokens: AuthTokens) async {
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "token": tokens.refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": CodexConstants.clientID
        ]) else { return }
        var request = URLRequest(url: CodexConstants.revokeURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func tokenRequest(body: Data, contentType: String, previous: AuthTokens?) async throws -> AuthTokens {
        var request = URLRequest(url: CodexConstants.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 25
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-meter-ios/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, fallback: "Authentication failed")
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let idToken = decoded.idToken ?? previous?.idToken ?? ""
        let refreshToken = decoded.refreshToken ?? previous?.refreshToken ?? ""
        let claims = JWTClaims.accountAndEmail(idToken: idToken, accessToken: decoded.accessToken)
        let tokens = AuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(60, decoded.expiresIn ?? 3_600))),
            accountId: claims.0.isEmpty ? previous?.accountId ?? "" : claims.0,
            email: claims.1.isEmpty ? previous?.email ?? "" : claims.1
        )
        guard tokens.isUsable else { throw MeterError.message("The authorization server returned incomplete credentials.") }
        return tokens
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let string = values.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(string.utf8)
    }
}

actor CodexAPI {
    static let shared = CodexAPI()

    func refreshAll(accountId: String) async throws -> (UsageSnapshot, ResetCreditsSnapshot?) {
        var tokens = try await usableTokens(accountId: accountId)
        var response = try await request(url: CodexConstants.usageURL, method: "GET", tokens: tokens)
        if response.status == 401 {
            tokens = try await AuthAPI.refresh(tokens)
            try KeychainTokenStore.save(tokens)
            response = try await request(url: CodexConstants.usageURL, method: "GET", tokens: tokens)
        }
        try validate(status: response.status, data: response.data, fallback: usageFallback(response.status))
        let usage = try UsageParser.parse(response.data)
        cache(usage, key: usageKey(accountId))

        let credits: ResetCreditsSnapshot?
        do {
            let creditResponse = try await request(url: CodexConstants.resetCreditsURL, method: "GET", tokens: tokens)
            try validate(status: creditResponse.status, data: creditResponse.data, fallback: "Could not load Codex reset credits")
            let parsed = try ResetCreditsParser.parse(creditResponse.data)
            cache(parsed, key: creditsKey(accountId))
            credits = parsed
        } catch {
            credits = cached(ResetCreditsSnapshot.self, key: creditsKey(accountId))
        }
        return (usage, credits)
    }

    func consumeBestResetCredit(accountId: String, credits: ResetCreditsSnapshot?) async throws -> String {
        var tokens = try await usableTokens(accountId: accountId)
        var body: [String: Any] = ["redeem_request_id": UUID().uuidString]
        if let id = credits?.preferredCredit?.id, !id.isEmpty { body["credit_id"] = id }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var response = try await request(url: CodexConstants.consumeResetURL, method: "POST", tokens: tokens, body: payload)
        if response.status == 401 {
            tokens = try await AuthAPI.refresh(tokens)
            try KeychainTokenStore.save(tokens)
            response = try await request(url: CodexConstants.consumeResetURL, method: "POST", tokens: tokens, body: payload)
        }
        try validate(status: response.status, data: response.data, fallback: "Could not apply the Codex reset")
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return object?["code"] as? String ?? "reset"
    }

    func cachedUsage(accountId: String) -> UsageSnapshot? {
        cached(UsageSnapshot.self, key: usageKey(accountId))
            ?? migrateLegacyCache(UsageSnapshot.self, legacyKey: SharedStore.usageKey, destinationKey: usageKey(accountId))
    }

    func cachedCredits(accountId: String) -> ResetCreditsSnapshot? {
        cached(ResetCreditsSnapshot.self, key: creditsKey(accountId))
            ?? migrateLegacyCache(ResetCreditsSnapshot.self, legacyKey: SharedStore.creditsKey, destinationKey: creditsKey(accountId))
    }

    func cacheSnapshots(usage: UsageSnapshot, credits: ResetCreditsSnapshot?, cacheId: String) {
        cache(usage, key: usageKey(cacheId))
        if let credits { cache(credits, key: creditsKey(cacheId)) }
    }

    func removeCache(accountId: String) {
        UserDefaults.standard.removeObject(forKey: usageKey(accountId))
        UserDefaults.standard.removeObject(forKey: creditsKey(accountId))
    }

    func publishWidgetSnapshots(_ snapshots: [AccountUsageSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: SharedStore.accountsKey)
        if let sharedDefaults = UserDefaults(suiteName: SharedStore.suiteName) {
            sharedDefaults.set(data, forKey: SharedStore.accountsKey)
            sharedDefaults.synchronize()
        }
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.suiteName
        ) {
            try? data.write(
                to: container.appendingPathComponent(SharedStore.accountsFileName),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func usableTokens(accountId: String) async throws -> AuthTokens {
        guard var tokens = KeychainTokenStore.load(accountId: accountId) else {
            throw MeterError.message("This ChatGPT account is no longer signed in.")
        }
        if tokens.shouldRefresh {
            tokens = try await AuthAPI.refresh(tokens)
            try KeychainTokenStore.save(tokens)
        }
        return tokens
    }

    private func request(url: URL, method: String, tokens: AuthTokens, body: Data? = nil) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-meter-ios/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(CodexConstants.originator, forHTTPHeaderField: "originator")
        if !tokens.accountId.isEmpty { request.setValue(tokens.accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeterError.message("The server returned an invalid response.") }
        return (data, http.statusCode)
    }

    private func usageFallback(_ status: Int) -> String {
        switch status {
        case 403: "Codex usage access was denied for this account."
        case 404: "The Codex usage endpoint is unavailable or has changed."
        default: "Usage refresh failed (HTTP \(status))."
        }
    }

    private func usageKey(_ accountId: String) -> String { "usage-snapshot-v2.\(accountId)" }
    private func creditsKey(_ accountId: String) -> String { "reset-credits-v2.\(accountId)" }

    private func cache<T: Encodable>(_ value: T, key: String, shared: Bool = false) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
            if shared { UserDefaults(suiteName: SharedStore.suiteName)?.set(data, forKey: key) }
        }
    }

    private func cached<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let data = UserDefaults(suiteName: SharedStore.suiteName)?.data(forKey: key)
            ?? UserDefaults.standard.data(forKey: key)
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func migrateLegacyCache<T: Codable>(_ type: T.Type, legacyKey: String, destinationKey: String) -> T? {
        guard let value = cached(type, key: legacyKey) else { return nil }
        cache(value, key: destinationKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults(suiteName: SharedStore.suiteName)?.removeObject(forKey: legacyKey)
        return value
    }
}

private func validate(response: URLResponse, data: Data, fallback: String) throws {
    guard let http = response as? HTTPURLResponse else { throw MeterError.message(fallback) }
    try validate(status: http.statusCode, data: data, fallback: "\(fallback) (HTTP \(http.statusCode)).")
}

private func validate(status: Int, data: Data, fallback: String) throws {
    guard !(200..<300).contains(status) else { return }
    if let decoded = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
        throw MeterError.message(decoded.errorDescription ?? decoded.error?.message ?? decoded.message ?? fallback)
    }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = object["error"] as? String, !error.isEmpty {
        throw MeterError.message(error)
    }
    throw MeterError.message(fallback)
}
