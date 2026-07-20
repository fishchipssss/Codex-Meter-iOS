import Foundation
import UserNotifications
import CodexMeterCore

enum ResetAlertScheduler {
    typealias AccountUsage = (id: String, name: String, usage: UsageSnapshot?)

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func requestPermissionAndSchedule(_ accounts: [AccountUsage]) async {
        _ = await requestPermission()
        await schedule(accounts)
    }

    static func schedule(_ accounts: [AccountUsage]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix("codex-meter-reset.") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        for account in accounts {
            guard let usage = account.usage else { continue }
            let accountLabel = accounts.count > 1 ? " for \(account.name)" : ""
            if UserDefaults.standard.bool(forKey: "alert-five-hour") {
                await add(
                    window: usage.effectiveFiveHour(),
                    identifier: "codex-meter-reset.\(account.id).five-hour",
                    title: "5-hour Codex limit reset",
                    body: "Your rolling Codex allowance\(accountLabel) is available again."
                )
            }
            if UserDefaults.standard.bool(forKey: "alert-weekly") {
                await add(
                    window: usage.weekly,
                    identifier: "codex-meter-reset.\(account.id).weekly",
                    title: "Weekly Codex limit reset",
                    body: "Your weekly Codex allowance\(accountLabel) is available again."
                )
            }
        }
    }

    static func notifyIfUnexpectedReset(
        accountID: String,
        accountName: String,
        accountCount: Int,
        previous: UsageSnapshot?,
        current: UsageSnapshot
    ) async {
        guard let previous else { return }
        let resets = UsageResetDetector.unexpectedResets(previous: previous, current: current)
        guard !resets.isEmpty else { return }

        let labels = resets.map(\.notificationLabel)
        let limitDescription = labels.count == 1 ? "\(labels[0]) limit" : "\(labels.joined(separator: " and ")) limits"
        let accountDescription = accountCount > 1 ? " for \(accountName)" : ""
        let content = UNMutableNotificationContent()
        content.title = "Codex limit reset detected"
        content.body = "Your \(limitDescription)\(accountDescription) reset earlier than expected."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "codex-meter-detected-reset.\(accountID).\(Int(current.fetchedAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func add(window: UsageWindow?, identifier: String, title: String, body: String) async {
        guard let date = window?.resetDate, date.timeIntervalSinceNow > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
