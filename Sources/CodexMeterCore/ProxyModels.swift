import Foundation

public struct ProxySetupCode: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let token: String

    public init(_ value: String) throws {
        guard
            let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme?.lowercased() == "codexmeter",
            components.host?.lowercased() == "proxy",
            components.path == "/add"
        else { throw MeterError.message("This is not a Codex Meter proxy setup code.") }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["v"] == "1" else { throw MeterError.message("This proxy uses an unsupported setup-code version.") }
        guard let id = UUID(uuidString: values["id"] ?? "") else { throw MeterError.message("The proxy setup code has an invalid identifier.") }
        guard
            let url = URL(string: values["url"] ?? ""),
            url.scheme?.lowercased() == "https", url.host != nil,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.path.isEmpty || url.path == "/"
        else {
            throw MeterError.message("The proxy must use a valid HTTPS URL.")
        }
        let token = values["token"] ?? ""
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        guard token.count >= 32, token.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
            throw MeterError.message("The proxy access token is invalid.")
        }
        self.id = id
        name = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.host ?? "Codex CLI"
        baseURL = url
        self.token = token
    }
}

public struct ParsedProxySnapshot: Equatable, Sendable {
    public let proxyId: UUID
    public let proxyName: String
    public let email: String
    public let usage: UsageSnapshot
    public let resetCredits: ResetCreditsSnapshot
}

public enum ProxySnapshotParser {
    public static func parse(_ data: Data, now: Date = .now) throws -> ParsedProxySnapshot {
        let decoded = try JSONDecoder.proxyDecoder.decode(ProxySnapshotEnvelope.self, from: data)
        guard decoded.schemaVersion == 1 else { throw MeterError.message("The proxy protocol version is unsupported.") }
        guard let proxyId = UUID(uuidString: decoded.proxy.id) else { throw MeterError.message("The proxy returned an invalid identifier.") }
        let windows = [decoded.rateLimit.primary, decoded.rateLimit.secondary].compactMap { $0?.model(now: now) }
        let fiveHour = nearest(windows, target: 18_000, range: 10_800...28_800)
        let weekly = nearest(windows, target: 604_800, range: 432_000...777_600)
        guard fiveHour != nil || weekly != nil else { throw MeterError.message("The proxy returned no recognizable Codex limits.") }
        let credits = decoded.resetCredits.credits.map { credit in
            ResetCredit(
                id: credit.id,
                resetType: credit.resetType,
                status: credit.status,
                grantedAt: credit.grantedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                expiresAt: credit.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                title: credit.title ?? "Codex reset",
                description: credit.description ?? ""
            )
        }
        let fetchedAt = decoded.fetchedAt ?? now
        return ParsedProxySnapshot(
            proxyId: proxyId,
            proxyName: decoded.proxy.name,
            email: decoded.account.email ?? "",
            usage: UsageSnapshot(
                planType: decoded.account.planType ?? "",
                allowed: decoded.rateLimit.rateLimitReachedType == nil,
                limitReached: decoded.rateLimit.rateLimitReachedType != nil,
                fiveHour: fiveHour,
                weekly: weekly,
                resetCreditsAvailable: decoded.resetCredits.availableCount,
                fetchedAt: fetchedAt
            ),
            resetCredits: ResetCreditsSnapshot(availableCount: decoded.resetCredits.availableCount, credits: credits, fetchedAt: fetchedAt)
        )
    }

    private static func nearest(_ windows: [UsageWindow], target: Int, range: ClosedRange<Int>) -> UsageWindow? {
        windows.filter { range.contains($0.windowSeconds) }.min { abs($0.windowSeconds - target) < abs($1.windowSeconds - target) }
    }
}

private struct ProxySnapshotEnvelope: Decodable {
    struct Proxy: Decodable { let id: String; let name: String }
    struct Account: Decodable {
        let email: String?
        let planType: String?
        enum CodingKeys: String, CodingKey { case email; case planType = "plan_type" }
    }
    struct RateLimit: Decodable {
        let rateLimitReachedType: String?
        let primary: Window?
        let secondary: Window?
        enum CodingKeys: String, CodingKey {
            case rateLimitReachedType = "rate_limit_reached_type"
            case primary, secondary
        }
    }
    struct Window: Decodable {
        let usedPercent: Int
        let windowDurationMinutes: Int?
        let resetsAt: Int?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowDurationMinutes = "window_duration_minutes"
            case resetsAt = "resets_at"
        }
        func model(now: Date) -> UsageWindow? {
            guard let minutes = windowDurationMinutes, minutes > 0 else { return nil }
            let epoch = max(0, resetsAt ?? 0)
            return UsageWindow(
                usedPercent: max(0, min(100, usedPercent)),
                windowSeconds: minutes * 60,
                resetAfterSeconds: max(0, epoch - Int(now.timeIntervalSince1970)),
                resetAtEpochSeconds: epoch
            )
        }
    }
    struct Credits: Decodable {
        let availableCount: Int
        let credits: [Credit]
        enum CodingKeys: String, CodingKey { case availableCount = "available_count"; case credits }
    }
    struct Credit: Decodable {
        let id: String
        let resetType: String
        let status: String
        let grantedAt: Int?
        let expiresAt: Int?
        let title: String?
        let description: String?
        enum CodingKeys: String, CodingKey {
            case id, status, title, description
            case resetType = "reset_type"
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
        }
    }
    let schemaVersion: Int
    let proxy: Proxy
    let account: Account
    let rateLimit: RateLimit
    let resetCredits: Credits
    let fetchedAt: Date?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case proxy, account
        case rateLimit = "rate_limit"
        case resetCredits = "reset_credits"
        case fetchedAt = "fetched_at"
    }
}

private extension JSONDecoder {
    static var proxyDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
