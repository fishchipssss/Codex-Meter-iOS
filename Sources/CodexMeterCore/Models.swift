import Foundation

public enum SharedStore {
    public static let suiteName = "group.com.picklemike.codexmeter"
    public static let usageKey = "usage-snapshot-v1"
    public static let creditsKey = "reset-credits-v1"
    public static let accountsKey = "account-usage-snapshots-v2"
    public static let accountsFileName = "account-usage-snapshots-v2.json"
}

public struct AccountUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let email: String
    public let nickname: String?
    public let usage: UsageSnapshot?
    public let sourceLabel: String?
    public let isStale: Bool?
    public let lastSuccessfulAt: Date?

    public init(id: String, email: String, nickname: String? = nil, usage: UsageSnapshot?, sourceLabel: String? = nil, isStale: Bool? = nil, lastSuccessfulAt: Date? = nil) {
        self.id = id
        self.email = email
        self.nickname = nickname
        self.usage = usage
        self.sourceLabel = sourceLabel
        self.isStale = isStale
        self.lastSuccessfulAt = lastSuccessfulAt
    }

    public var displayName: String {
        let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNickname.isEmpty { return trimmedNickname }
        return email.isEmpty ? "ChatGPT account" : email
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowSeconds: Int
    public let resetAfterSeconds: Int
    public let resetAtEpochSeconds: Int

    public init(usedPercent: Int, windowSeconds: Int, resetAfterSeconds: Int, resetAtEpochSeconds: Int) {
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAtEpochSeconds = resetAtEpochSeconds
    }

    public var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    public var resetDate: Date? {
        resetAtEpochSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(resetAtEpochSeconds)) : nil
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let planType: String
    public let allowed: Bool
    public let limitReached: Bool
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?
    public let resetCreditsAvailable: Int?
    public let fetchedAt: Date

    public init(planType: String, allowed: Bool, limitReached: Bool, fiveHour: UsageWindow?, weekly: UsageWindow?, resetCreditsAvailable: Int?, fetchedAt: Date) {
        self.planType = planType
        self.allowed = allowed
        self.limitReached = limitReached
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.resetCreditsAvailable = resetCreditsAvailable
        self.fetchedAt = fetchedAt
    }

    /// Returns the rolling window only when it behaves like a real five-hour
    /// allowance. This prevents a weekly-only response from appearing twice.
    public func effectiveFiveHour(at date: Date = .now) -> UsageWindow? {
        guard let fiveHour, let reset = fiveHour.resetDate else { return nil }
        let interval = reset.timeIntervalSince(date)
        guard interval > 0, interval <= 5 * 60 * 60 else { return nil }
        if let weeklyReset = weekly?.resetDate,
           abs(weeklyReset.timeIntervalSince(reset)) <= 5 * 60 {
            return nil
        }
        return fiveHour
    }
}

public enum UsageLimitKind: String, Equatable, Sendable {
    case fiveHour
    case weekly

    public var notificationLabel: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        }
    }
}

public enum UsageResetDetector {
    /// Detects a meaningful usage drop that occurred before the server's
    /// previously reported reset time. Normal scheduled resets are excluded.
    public static func unexpectedResets(
        previous: UsageSnapshot,
        current: UsageSnapshot,
        earlyByAtLeast gracePeriod: TimeInterval = 5 * 60
    ) -> [UsageLimitKind] {
        guard current.fetchedAt > previous.fetchedAt else { return [] }

        var resets: [UsageLimitKind] = []
        if resetOccurred(
            previous: previous.effectiveFiveHour(at: previous.fetchedAt),
            current: current.effectiveFiveHour(at: current.fetchedAt),
            fetchedAt: current.fetchedAt,
            gracePeriod: gracePeriod
        ) {
            resets.append(.fiveHour)
        }
        if resetOccurred(
            previous: previous.weekly, current: current.weekly,
            fetchedAt: current.fetchedAt, gracePeriod: gracePeriod
        ) {
            resets.append(.weekly)
        }
        return resets
    }

    private static func resetOccurred(
        previous: UsageWindow?, current: UsageWindow?, fetchedAt: Date,
        gracePeriod: TimeInterval
    ) -> Bool {
        guard let previous, let current, let expectedReset = previous.resetDate else { return false }
        guard expectedReset.timeIntervalSince(fetchedAt) > gracePeriod else { return false }
        let decrease = previous.usedPercent - current.usedPercent
        return previous.usedPercent >= 10 && decrease >= 10
    }
}

public struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String
    public let description: String

    public init(id: String, resetType: String, status: String, grantedAt: Date?, expiresAt: Date?, title: String, description: String) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }

    public var isAvailable: Bool { status.caseInsensitiveCompare("available") == .orderedSame }
}

public struct ResetCreditsSnapshot: Codable, Equatable, Sendable {
    public let availableCount: Int
    public let credits: [ResetCredit]
    public let fetchedAt: Date

    public init(availableCount: Int, credits: [ResetCredit], fetchedAt: Date) {
        self.availableCount = availableCount
        self.credits = credits
        self.fetchedAt = fetchedAt
    }

    public var preferredCredit: ResetCredit? {
        credits
            .filter { $0.isAvailable && ($0.expiresAt == nil || $0.expiresAt! > Date()) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            .first
    }
}

public enum MeterError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case let .message(message): message }
    }
}
