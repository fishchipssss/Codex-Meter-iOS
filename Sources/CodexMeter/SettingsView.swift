import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: MeterViewModel
    @AppStorage("refresh-on-launch") private var refreshOnLaunch = true
    @AppStorage("alert-five-hour") private var alertFiveHour = false
    @AppStorage("alert-weekly") private var alertWeekly = false
    @AppStorage(UsageBackgroundRefresh.enabledKey) private var backgroundRefresh = true
    @AppStorage(UsageBackgroundRefresh.intervalKey) private var backgroundRefreshMinutes = 30
    @AppStorage(UsageBackgroundRefresh.lastScheduledKey) private var lastBackgroundSchedule = 0.0
    @AppStorage(UsageBackgroundRefresh.lastAttemptKey) private var lastBackgroundAttempt = 0.0
    @AppStorage(UsageBackgroundRefresh.scheduleErrorKey) private var backgroundScheduleError = ""
    @State private var accountToRemove: AccountMeterState?
    @State private var accountToRename: AccountMeterState?
    @State private var nicknameDraft = ""
    @State private var reorderTargetID: String?
    @State private var confirmsSignOutAll = false
    @State private var showsSignInOptions = false
    @State private var showsProxySetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                MeterGlassGroup(spacing: 18) {
                    LazyVStack(spacing: 18) {
                        refreshSection
                        resetAlertsSection
                        accountsSection
                        appReviewSection
                        aboutSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .background { MeterBackdrop() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showsProxySetup) { ProxySetupView() }
            .overlay {
                if showsSignInOptions {
                    SignInMethodDialog(
                        isPresented: $showsSignInOptions,
                        onDirectLogin: { model.signIn(using: .browser) },
                        onDeviceCode: { model.signIn(using: .deviceCode) },
                        onProxy: { showsProxySetup = true }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .animation(.snappy, value: showsSignInOptions)
            .confirmationDialog(
                "Remove this account?",
                isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove account", role: .destructive) {
                    if let accountToRemove { model.removeAccount(accountToRemove.id) }
                    accountToRemove = nil
                }
                Button("Cancel", role: .cancel) { accountToRemove = nil }
            } message: {
                Text(removalDescription)
            }
            .confirmationDialog("Sign out of every account?", isPresented: $confirmsSignOutAll, titleVisibility: .visible) {
                Button("Sign out of all accounts", role: .destructive) { model.signOutAll() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Profile nickname", isPresented: Binding(
                get: { accountToRename != nil },
                set: { if !$0 { accountToRename = nil } }
            )) {
                TextField("Nickname", text: $nicknameDraft)
                Button("Save") {
                    if let id = accountToRename?.id { model.setNickname(nicknameDraft, for: id) }
                    accountToRename = nil
                }
                if accountToRename?.nickname != nil {
                    Button("Remove nickname", role: .destructive) {
                        if let id = accountToRename?.id { model.setNickname(nil, for: id) }
                        accountToRename = nil
                    }
                }
                Button("Cancel", role: .cancel) { accountToRename = nil }
            } message: {
                Text("Use a short name that is easier to recognize in the app and widgets.")
            }
        }
        .tint(MeterTheme.blue)
        .onChange(of: alertFiveHour) { _, _ in Task { await model.updateResetAlerts() } }
        .onChange(of: alertWeekly) { _, _ in Task { await model.updateResetAlerts() } }
        .onChange(of: backgroundRefresh) { _, enabled in
            if enabled { UsageBackgroundRefresh.schedule() } else { UsageBackgroundRefresh.cancel() }
        }
        .onChange(of: backgroundRefreshMinutes) { _, _ in UsageBackgroundRefresh.schedule() }
    }

    private var refreshSection: some View {
        settingsSection(
            "Refresh",
            footer: "iOS treats the selected interval as the earliest requested refresh time. Actual timing depends on battery, network, and system conditions."
        ) {
            Toggle("Refresh when opened", isOn: $refreshOnLaunch).disabled(model.isDemoMode)
            settingsDivider
            Toggle("Refresh in background", isOn: $backgroundRefresh).disabled(model.isDemoMode)
            settingsDivider
            Picker("Refresh interval", selection: $backgroundRefreshMinutes) {
                ForEach(UsageBackgroundRefresh.allowedIntervals, id: \.self) { minutes in
                    Text(intervalLabel(minutes)).tag(minutes)
                }
            }
            .disabled(!backgroundRefresh || model.isDemoMode)
            settingsDivider
            Button { Task { await model.refresh() } } label: {
                Label("Refresh all accounts", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.isSignedIn || model.isRefreshing)
            if lastBackgroundSchedule > 0 {
                settingsDivider
                LabeledContent("Request submitted", value: backgroundDate(lastBackgroundSchedule)).font(.subheadline)
            }
            if lastBackgroundAttempt > 0 {
                settingsDivider
                LabeledContent("Last background attempt", value: backgroundDate(lastBackgroundAttempt)).font(.subheadline)
            }
            if !backgroundScheduleError.isEmpty {
                settingsDivider
                Text(backgroundScheduleError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var resetAlertsSection: some View {
        settingsSection(
            "Reset alerts",
            footer: model.isDemoMode
                ? "Reset notifications are disabled while sample data is active."
                : "Scheduled alerts use reported reset times. Unexpected early resets are detected automatically."
        ) {
            Toggle("5-hour reset", isOn: $alertFiveHour).disabled(model.isDemoMode)
            settingsDivider
            Toggle("Weekly reset", isOn: $alertWeekly).disabled(model.isDemoMode)
        }
    }

    private var accountsSection: some View {
        settingsSection("Accounts") {
            ForEach(model.accounts) { account in
                accountRow(account)
                settingsDivider
            }
            if model.isDemoMode {
                Label("Sample profiles are read-only", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                Button { showsSignInOptions = true } label: {
                    Label("Add account", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.isSigningIn)
                if model.accounts.count > 1 {
                    settingsDivider
                    Button("Sign out of all accounts", role: .destructive) { confirmsSignOutAll = true }
                }
            }
        }
    }

    private var appReviewSection: some View {
        settingsSection(
            "App Review",
            footer: "Shows two local sample profiles without authentication or network access. Disable it to restore your connected accounts."
        ) {
            Toggle("Demo mode", isOn: Binding(
                get: { model.isDemoMode },
                set: { model.setDemoMode($0) }
            ))
        }
    }

    private var aboutSection: some View {
        settingsSection("About") {
            LabeledContent("Version", value: "0.1.0")
            settingsDivider
            Link("Android inspiration", destination: URL(string: "https://github.com/BenItBuhner/Codex-Meter")!)
            settingsDivider
            Text("Codex Meter is an unofficial personal client and is not affiliated with OpenAI.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func accountRow(_ account: AccountMeterState) -> some View {
        return HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(MeterTheme.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.displayName).lineLimit(1)
                    if let label = account.sourceLabel {
                        Text(label).font(.system(size: 8, weight: .heavy)).foregroundStyle(MeterTheme.blue)
                    }
                }
                Text(accountSubtitle(for: account)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isDemoMode {
                Button {
                    nicknameDraft = account.nickname ?? ""
                    accountToRename = account
                } label: {
                    Image(systemName: "pencil").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nickname \(account.displayName)")
                Button(role: .destructive) { accountToRemove = account } label: {
                    Image(systemName: "trash").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(account.displayName)")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MeterTheme.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
                    .draggable(account.id) {
                        Label(account.displayName, systemImage: "person.crop.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .meterGlassCapsule()
                    }
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { accountIDs, _ in
            guard let sourceID = accountIDs.first else { return false }
            withAnimation(.snappy) { model.moveAccount(sourceID, to: account.id) }
            reorderTargetID = nil
            return true
        } isTargeted: { isTargeted in
            reorderTargetID = isTargeted ? account.id : nil
        }
        .overlay {
            if reorderTargetID == account.id {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MeterTheme.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAction(named: "Move up") { model.moveAccount(account.id, by: -1) }
        .accessibilityAction(named: "Move down") { model.moveAccount(account.id, by: 1) }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(MeterTheme.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .meterGlassCard(cornerRadius: 24)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(MeterTheme.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var settingsDivider: some View { Divider().opacity(0.55) }

    private var removalDescription: String {
        guard let account = accountToRemove else { return "This removes the account and its cached usage." }
        if case .proxy = account.source { return "This forgets the proxy connection and cached usage. It does not sign the computer out of Codex." }
        return "This signs out only \(account.displayName) and removes its cached usage."
    }

    private func accountSubtitle(for account: AccountMeterState) -> String {
        if account.nickname != nil, !account.email.isEmpty { return account.email }
        if let proxyName = account.proxyName { return proxyName }
        if let planType = account.usage?.planType { return planType.planLabel }
        return "Connected"
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes >= 60 ? (minutes == 60 ? "1 hour" : "2 hours") : "\(minutes) minutes"
    }

    private func backgroundDate(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }
}
