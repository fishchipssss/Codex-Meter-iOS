import Foundation

private struct APIUsageEnvelope: Decodable {
    let planType: String?
    let rateLimit: APIRateLimit?
    let additionalRateLimits: [APIAdditionalLimit]?
    let resetCredits: APIResetCreditSummary?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case resetCredits = "rate_limit_reset_credits"
    }
}

private struct APIRateLimit: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primary: APIUsageWindow?
    let secondary: APIUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primary = "primary_window"
        case secondary = "secondary_window"
    }
}

private struct APIAdditionalLimit: Decodable {
    let rateLimit: APIRateLimit?
    let primary: APIUsageWindow?
    let secondary: APIUsageWindow?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case primary = "primary_window"
        case secondary = "secondary_window"
    }
}

private struct APIResetCreditSummary: Decodable {
    let availableCount: Int?
    enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
}

private struct APIUsageWindow: Decodable {
    let usedPercent: Double
    let windowSeconds: Int
    let resetAfterSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    var model: UsageWindow {
        UsageWindow(
            usedPercent: max(0, min(100, Int(usedPercent.rounded()))),
            windowSeconds: windowSeconds,
            resetAfterSeconds: max(0, resetAfterSeconds ?? 0),
            resetAtEpochSeconds: max(0, resetAt ?? 0)
        )
    }
}

public enum UsageParser {
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let envelope = try JSONDecoder().decode(APIUsageEnvelope.self, from: data)
        let primaryWindows = [envelope.rateLimit?.primary, envelope.rateLimit?.secondary].compactMap { $0?.model }
        let additionalWindows = (envelope.additionalRateLimits ?? []).flatMap { entry -> [UsageWindow] in
            let limit = entry.rateLimit
            return [limit?.primary?.model ?? entry.primary?.model, limit?.secondary?.model ?? entry.secondary?.model].compactMap { $0 }
        }

        let windows = primaryWindows + additionalWindows
        let fiveHour = nearest(windows, target: 18_000, range: 10_800...28_800)
        let remaining = windows.filter { $0 != fiveHour }
        let weekly = nearest(remaining, target: 604_800, range: 432_000...777_600)
            ?? remaining.filter { $0.windowSeconds > 86_400 }.max { $0.windowSeconds < $1.windowSeconds }

        guard fiveHour != nil || weekly != nil else {
            throw MeterError.message("OpenAI returned no recognizable Codex usage windows.")
        }
        return UsageSnapshot(
            planType: envelope.planType ?? "",
            allowed: envelope.rateLimit?.allowed ?? true,
            limitReached: envelope.rateLimit?.limitReached ?? false,
            fiveHour: fiveHour,
            weekly: weekly,
            resetCreditsAvailable: envelope.resetCredits?.availableCount,
            fetchedAt: now
        )
    }

    private static func nearest(_ windows: [UsageWindow], target: Int, range: ClosedRange<Int>) -> UsageWindow? {
        windows
            .filter { range.contains($0.windowSeconds) }
            .min { abs($0.windowSeconds - target) < abs($1.windowSeconds - target) }
    }
}

private struct APIResetCreditsEnvelope: Decodable {
    let availableCount: Int?
    let credits: [APIResetCredit]?
    enum CodingKeys: String, CodingKey { case availableCount = "available_count"; case credits }
}

private struct APIResetCredit: Decodable {
    let id: String?
    let resetType: String?
    let status: String?
    let grantedAt: String?
    let expiresAt: String?
    let title: String?
    let description: String?
    enum CodingKeys: String, CodingKey {
        case id, status, title, description
        case resetType = "reset_type"
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }
}

public enum ResetCreditsParser {
    public static func parse(_ data: Data, now: Date = Date()) throws -> ResetCreditsSnapshot {
        let envelope = try JSONDecoder().decode(APIResetCreditsEnvelope.self, from: data)
        let formatter = ISO8601DateFormatter()
        let credits = (envelope.credits ?? []).map {
            ResetCredit(
                id: $0.id ?? "",
                resetType: $0.resetType ?? "",
                status: $0.status ?? "",
                grantedAt: $0.grantedAt.flatMap(formatter.date),
                expiresAt: $0.expiresAt.flatMap(formatter.date),
                title: $0.title ?? "Codex reset",
                description: $0.description ?? ""
            )
        }
        return ResetCreditsSnapshot(
            availableCount: max(0, envelope.availableCount ?? credits.filter(\.isAvailable).count),
            credits: credits,
            fetchedAt: now
        )
    }
}
