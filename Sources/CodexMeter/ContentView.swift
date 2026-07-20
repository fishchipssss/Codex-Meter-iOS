import SwiftUI
import UIKit
import CodexMeterCore

struct ContentView: View {
    @EnvironmentObject private var model: MeterViewModel
    @State private var showsSettings = false
    @State private var showsSignInOptions = false
    @State private var showsProxySetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    statusHeader
                    if model.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.accounts) { account in
                            AccountDashboardSection(account: account)
                        }
                    }
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .refreshable { await model.refresh() }
            .background { MeterBackdrop() }
            .navigationTitle("Codex Meter")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.isSignedIn && !model.isDemoMode {
                        Button { showsSignInOptions = true } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .disabled(model.isSigningIn)
                        .accessibilityLabel("Add account")
                    }
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .sheet(isPresented: $showsProxySetup) { ProxySetupView() }
            .alert("Codex Meter", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toastMessage {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .meterGlassCapsule()
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(2.2))
                            withAnimation { model.toastMessage = nil }
                        }
                }
            }
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
        }
        .tint(MeterTheme.blue)
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [MeterTheme.blue, MeterTheme.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "terminal.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).font(.headline)
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(MeterTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isSignedIn {
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                        .rotationEffect(model.isRefreshing ? .degrees(360) : .zero)
                        .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
                        .frame(width: 38, height: 38)
                        .meterGlassCircle()
                }
                .disabled(model.isRefreshing)
                .accessibilityLabel("Refresh all accounts")
            }
        }
        .padding(.horizontal, 2)
    }

    private var headerTitle: String {
        switch model.accounts.count {
        case 0: "Not connected"
        case 1: "1 account connected"
        default: "\(model.accounts.count) accounts connected"
        }
    }

    private var headerSubtitle: String {
        if model.isDemoMode { return "Offline sample data for App Review" }
        if model.isRefreshing { return "Refreshing account limits…" }
        let latest = model.accounts.compactMap { $0.usage?.fetchedAt }.max()
        if let latest { return "Updated \(latest.formatted(.relative(presentation: .numeric)))" }
        return model.isSignedIn ? "Waiting for usage" : "Sign in to view your allowances"
    }

    private var emptyState: some View {
        MeterCard {
            VStack(spacing: 18) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(MeterTheme.blue)
                VStack(spacing: 7) {
                    Text("All your limits, in one place").font(.title3.weight(.bold))
                    Text("Connect one or more ChatGPT accounts to see each account’s live Codex limits and resets.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(MeterTheme.secondary)
                }
                Button {
                    if model.isSigningIn { model.cancelSignIn() } else { showsSignInOptions = true }
                } label: {
                    HStack {
                        if model.isSigningIn { ProgressView().tint(.white) }
                        Text(model.isSigningIn ? "Cancel sign-in" : "Add account")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .meterProminentButton()
                .buttonBorderShape(.roundedRectangle(radius: 17))
            }
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        Text(model.isDemoMode
            ? "Demo mode · Sample data stays on this device"
            : "Unofficial client · Credentials stay in this device’s Keychain")
            .font(.caption)
            .foregroundStyle(MeterTheme.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }
}

private struct AccountDashboardSection: View {
    @EnvironmentObject private var model: MeterViewModel
    let account: AccountMeterState
    @State private var isResetExpanded = false

    var body: some View {
        MeterGlassGroup(spacing: 14) {
            VStack(spacing: 14) {
                usageCards
                accountCard
                if let message = account.errorMessage { accountError(message) }
                resetCard
            }
        }
    }

    private var usageCards: some View {
        VStack(spacing: 14) {
            if account.usage == nil || account.usage?.effectiveFiveHour() != nil {
                UsageWaveCard(
                    title: "5 hour",
                    symbol: "clock.fill",
                    window: account.usage?.effectiveFiveHour(),
                    isConnected: true,
                    colors: [Color(red: 0.08, green: 0.46, blue: 1), Color(red: 0.18, green: 0.68, blue: 1)],
                    waveOffset: 0
                )
            }
            if account.usage == nil || account.usage?.weekly != nil {
                UsageWaveCard(
                    title: "Weekly",
                    symbol: "calendar.badge.clock",
                    window: account.usage?.weekly,
                    isConnected: true,
                    colors: [MeterTheme.deepBlue, MeterTheme.blue],
                    waveOffset: .pi
                )
            }
        }
    }

    private var accountCard: some View {
        MeterCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(MeterTheme.blue.opacity(0.16))
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 29))
                        .foregroundStyle(MeterTheme.blue)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(account.displayName).font(.headline).lineLimit(1)
                        if let sourceLabel = account.sourceLabel {
                            Text(sourceLabel)
                                .font(.system(size: 8, weight: .heavy))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .foregroundStyle(MeterTheme.blue)
                                .background(MeterTheme.blue.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(accountSubtitle)
                        .font(.subheadline).foregroundStyle(MeterTheme.secondary).lineLimit(1)
                }
                Spacer()
                if account.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.refresh(accountId: account.id) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 34, height: 34)
                            .meterGlassCircle()
                    }
                    .accessibilityLabel("Refresh \(account.displayName)")
                }
            }
        }
    }

    private var accountSubtitle: String {
        let plan = account.usage?.planType.planLabel ?? "Codex"
        if let proxyName = account.proxyName { return "\(plan) · \(proxyName)" }
        return plan
    }

    private func accountError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.isStale ? "Proxy offline · showing cached limits" : "Refresh failed")
                    .font(.caption.weight(.semibold)).foregroundStyle(MeterTheme.secondary)
                if account.isStale, let date = account.lastSuccessfulRefresh {
                    Text("Last updated \(date.formatted(.relative(presentation: .numeric)))")
                        .font(.caption2).foregroundStyle(MeterTheme.tertiary)
                } else if !account.isStale {
                    Text(message).font(.caption2).foregroundStyle(MeterTheme.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var resetCard: some View {
        MeterCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy) { isResetExpanded.toggle() }
                } label: {
                    HStack {
                        Label("Rate-limit resets", systemImage: "bolt.circle.fill")
                            .font(.headline)
                        Spacer()
                        Text("\(account.resetCount) available")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MeterTheme.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MeterTheme.secondary)
                            .rotationEffect(.degrees(isResetExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isResetExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        Divider().padding(.top, 16)
                        Text(resetCreditDescription)
                            .font(.subheadline)
                            .foregroundStyle(MeterTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await model.useResetCredit(accountId: account.id) }
                        } label: {
                            Label("Use a reset", systemImage: "arrow.counterclockwise.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .meterProminentButton()
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                        .disabled(account.resetCount <= 0 || account.isRefreshing)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var resetCreditDescription: String {
        guard let credit = account.resetCredits?.preferredCredit else {
            return "Use an available reset when you need to reopen this account’s Codex rate-limit windows."
        }
        if let expiry = credit.expiresAt {
            return "Your next reset expires \(expiry.formatted(.relative(presentation: .named)))."
        }
        return credit.description.isEmpty ? "A Codex rate-limit reset is ready to use." : credit.description
    }
}

struct MeterCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(18)
            .meterGlassCard()
    }
}

enum MeterTheme {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
    static let panel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.055, blue: 0.095, alpha: 1)
            : UIColor(red: 0.945, green: 0.970, blue: 1, alpha: 1)
    })
    static let raised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.105, blue: 0.17, alpha: 1)
            : UIColor(red: 0.88, green: 0.93, blue: 1, alpha: 1)
    })
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    static let border = Color(uiColor: .separator).opacity(0.34)
    static let blue = Color(red: 0.08, green: 0.46, blue: 1)
    static let deepBlue = Color(red: 0.02, green: 0.25, blue: 0.76)
}

extension String {
    var planLabel: String {
        guard !isEmpty else { return "" }
        return split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct SignInMethodDialog: View {
    @Binding var isPresented: Bool
    let onDirectLogin: () -> Void
    let onDeviceCode: () -> Void
    let onProxy: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 18) {
                VStack(spacing: 7) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(MeterTheme.blue)
                    Text("Add an account")
                        .font(.title2.bold())
                    Text("Choose how you want to connect Codex.")
                        .font(.subheadline)
                        .foregroundStyle(MeterTheme.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 11) {
                    dialogButton("Direct ChatGPT login", symbol: "safari.fill", prominent: true) {
                        perform(onDirectLogin)
                    }
                    dialogButton("Device code authorization", symbol: "number.square.fill") {
                        perform(onDeviceCode)
                    }
                    dialogButton("Codex CLI proxy", symbol: "terminal.fill") {
                        perform(onProxy)
                    }
                }

                Button("Cancel") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(MeterTheme.secondary)
            }
            .padding(24)
            .frame(maxWidth: 360)
            .meterGlassCard(cornerRadius: 30)
            .padding(.horizontal, 28)
        }
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func dialogButton(
        _ title: String,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .modifier(DialogButtonStyle(prominent: prominent))
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    private func perform(_ action: () -> Void) {
        isPresented = false
        action()
    }

    private func dismiss() {
        isPresented = false
    }
}

private struct DialogButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
