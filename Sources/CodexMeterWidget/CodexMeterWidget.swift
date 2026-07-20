import CodexMeterCore
import SwiftUI
import UIKit
import WidgetKit

@main
struct CodexAllowanceWidget: Widget {
    let kind = "CodexAllowanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AllowanceProvider()) { entry in
            AllowanceWidgetView(entry: entry)
                .unredacted()
                .containerBackground(for: .widget) { WidgetTheme.background }
        }
        .configurationDisplayName("Codex allowances")
        .description("See the Codex limits for your connected accounts.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct AllowanceEntry: TimelineEntry {
    let date: Date
    let accounts: [AccountUsageSnapshot]
    let isPlaceholder: Bool
}

struct AllowanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllowanceEntry {
        AllowanceEntry(date: .now, accounts: [], isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (AllowanceEntry) -> Void) {
        completion(AllowanceEntry(date: .now, accounts: context.isPreview ? [.preview] : loadAccounts(), isPlaceholder: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AllowanceEntry>) -> Void) {
        let accounts = loadAccounts()
        let nextReset = accounts.flatMap {
            [$0.usage?.effectiveFiveHour(at: .now)?.resetDate, $0.usage?.weekly?.resetDate]
        }
            .compactMap { $0 }
            .filter { $0 > .now }
            .min()
        let refresh = min(nextReset ?? .distantFuture, Date().addingTimeInterval(30 * 60))
        completion(Timeline(entries: [AllowanceEntry(date: .now, accounts: accounts, isPlaceholder: false)], policy: .after(refresh)))
    }

    private func loadAccounts() -> [AccountUsageSnapshot] {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.suiteName
        ) {
            let url = container.appendingPathComponent(SharedStore.accountsFileName)
            if let data = try? Data(contentsOf: url),
               let accounts = try? JSONDecoder().decode([AccountUsageSnapshot].self, from: data) {
                return accounts
            }
        }
        guard let defaults = UserDefaults(suiteName: SharedStore.suiteName) else { return [] }
        if let data = defaults.data(forKey: SharedStore.accountsKey),
           let accounts = try? JSONDecoder().decode([AccountUsageSnapshot].self, from: data) {
            return accounts
        }
        guard
            let data = defaults.data(forKey: SharedStore.usageKey),
            let usage = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else { return [] }
        return [AccountUsageSnapshot(id: "legacy", email: "ChatGPT account", usage: usage)]
    }
}

struct AllowanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AllowanceEntry

    var body: some View {
        Group {
            if entry.isPlaceholder {
                placeholder
            } else if family == .systemSmall {
                small
            } else {
                medium
            }
        }
        .padding(family == .systemSmall ? 14 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 7) {
            widgetHeader
            Spacer()
            Text("Open Codex Meter")
                .font(.headline)
            Text("to sync the widget")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            widgetHeader
            if let metric = smallMetric {
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(metric.window.remainingPercent)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("%")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(WidgetTheme.muted)
                }
                .foregroundStyle(WidgetTheme.blue)
                Text(metric.account.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                LimitBar(percent: metric.window.remainingPercent)
                HStack(spacing: 4) {
                    Text(metric.label.uppercased())
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(WidgetTheme.blue)
                    Spacer(minLength: 2)
                    resetLabel(metric.window)
                }
            } else {
                Spacer()
                Text("Open Codex Meter").font(.headline)
                Text("to add an account").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var medium: some View {
        VStack(spacing: 7) {
            widgetHeader
            if entry.accounts.isEmpty {
                Spacer()
                Text("Open Codex Meter to add an account").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.accounts.prefix(2)) { account in
                    accountRow(account)
                }
            }
        }
    }

    private func accountRow(_ account: AccountUsageSnapshot) -> some View {
        let fiveHour = account.usage?.effectiveFiveHour(at: entry.date)
        return HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                HStack(spacing: 4) {
                    if account.isStale == true {
                        Text("STALE").foregroundStyle(.orange)
                    } else if let source = account.sourceLabel {
                        Text(source).foregroundStyle(WidgetTheme.blue)
                    } else {
                        Text(account.usage?.planType.uppercased() ?? "CODEX")
                            .foregroundStyle(WidgetTheme.muted)
                    }
                }
                .font(.system(size: 7, weight: .heavy))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let fiveHour { metric("5H", fiveHour, wide: false) }
            if let weekly = account.usage?.weekly { metric("WEEK", weekly, wide: fiveHour == nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxHeight: .infinity)
        .background(WidgetTheme.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func metric(_ title: String, _ window: UsageWindow, wide: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(window.remainingPercent)%")
                .font(.system(size: wide ? 24 : 21, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetTheme.blue)
            HStack(spacing: 4) {
                Text(title)
                if wide, let reset = window.resetDate {
                    Text("· \(reset, style: .relative)")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(WidgetTheme.muted)
            LimitBar(percent: window.remainingPercent)
                .frame(width: wide ? 82 : 48)
        }
        .frame(width: wide ? 90 : 54, alignment: .trailing)
    }

    private var widgetHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(WidgetTheme.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("CODEX")
                .font(.caption2.weight(.heavy))
            Spacer()
            Text(accountCountLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(WidgetTheme.muted)
        }
    }

    private var accountCountLabel: String {
        entry.accounts.count == 1 ? "1 ACCOUNT" : "\(entry.accounts.count) ACCOUNTS"
    }

    private var smallMetric: (account: AccountUsageSnapshot, window: UsageWindow, label: String)? {
        let values = entry.accounts.flatMap { account -> [(AccountUsageSnapshot, UsageWindow, String)] in
            var metrics: [(AccountUsageSnapshot, UsageWindow, String)] = []
            if let window = account.usage?.effectiveFiveHour(at: entry.date) {
                metrics.append((account, window, "5-hour"))
            }
            if let window = account.usage?.weekly {
                metrics.append((account, window, "Weekly"))
            }
            return metrics
        }
        return values.min { $0.1.remainingPercent < $1.1.remainingPercent }
    }

    private func resetLabel(_ window: UsageWindow) -> some View {
        Group {
            if let reset = window.resetDate { Text("Resets \(reset, style: .relative)") }
            else { Text("Reset pending") }
        }
        .font(.caption2)
        .foregroundStyle(WidgetTheme.muted)
        .lineLimit(1)
    }
}

private struct LimitBar: View {
    let percent: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetTheme.track)
                Capsule()
                    .fill(WidgetTheme.blue)
                    .frame(width: max(3, proxy.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: 3)
    }
}

private enum WidgetTheme {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
    static let panel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.035, green: 0.075, blue: 0.13, alpha: 1)
            : UIColor(red: 0.92, green: 0.96, blue: 1, alpha: 1)
    })
    static let muted = Color(uiColor: .secondaryLabel)
    static let track = Color(uiColor: .separator).opacity(0.35)
    static let blue = Color(red: 0.08, green: 0.46, blue: 1)
}

private extension AccountUsageSnapshot {
    static var preview: AccountUsageSnapshot {
        AccountUsageSnapshot(
            id: "preview",
            email: "mike@example.com",
            usage: UsageSnapshot(
                planType: "plus",
                allowed: true,
                limitReached: false,
                fiveHour: UsageWindow(usedPercent: 38, windowSeconds: 18_000, resetAfterSeconds: 5_400, resetAtEpochSeconds: Int(Date().addingTimeInterval(5_400).timeIntervalSince1970)),
                weekly: UsageWindow(usedPercent: 64, windowSeconds: 604_800, resetAfterSeconds: 250_000, resetAtEpochSeconds: Int(Date().addingTimeInterval(250_000).timeIntervalSince1970)),
                resetCreditsAvailable: 2,
                fetchedAt: .now
            )
        )
    }
}
