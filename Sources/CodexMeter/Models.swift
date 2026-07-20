import Foundation

public struct AuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let expiresAt: Date
    public let accountId: String
    public let email: String

    public var isUsable: Bool { !accessToken.isEmpty && !refreshToken.isEmpty }
    public var shouldRefresh: Bool { expiresAt.timeIntervalSinceNow < 300 }

    public func mergingRefresh(_ replacement: AuthTokens) -> AuthTokens {
        AuthTokens(
            accessToken: replacement.accessToken,
            refreshToken: replacement.refreshToken.isEmpty ? refreshToken : replacement.refreshToken,
            idToken: replacement.idToken.isEmpty ? idToken : replacement.idToken,
            expiresAt: replacement.expiresAt,
            accountId: replacement.accountId.isEmpty ? accountId : replacement.accountId,
            email: replacement.email.isEmpty ? email : replacement.email
        )
    }
}

enum CodexConstants {
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let revokeURL = URL(string: "https://auth.openai.com/oauth/revoke")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let consumeResetURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let scope = "openid profile email offline_access"
    static let originator = "codex-meter-ios"
    static let callbackPorts: [UInt16] = [1455, 1457]
}

enum JWTClaims {
    static func accountAndEmail(idToken: String, accessToken: String) -> (String, String) {
        let id = parse(idToken)
        let access = parse(accessToken)
        return (id.account.isEmpty ? access.account : id.account, id.email.isEmpty ? access.email : id.email)
    }

    private static func parse(_ token: String) -> (account: String, email: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return ("", "") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard
            let data = Data(base64Encoded: encoded),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", "") }
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let organizations = object["organizations"] as? [[String: Any]]
        let account = (object["chatgpt_account_id"] as? String)
            ?? (auth?["chatgpt_account_id"] as? String)
            ?? (organizations?.first?["id"] as? String)
            ?? ""
        return (account, object["email"] as? String ?? "")
    }
}
