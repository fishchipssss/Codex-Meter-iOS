import SwiftUI

struct MeterBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            MeterTheme.background
            RadialGradient(
                colors: [MeterTheme.blue.opacity(colorScheme == .dark ? 0.20 : 0.13), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 330
            )
            RadialGradient(
                colors: [MeterTheme.deepBlue.opacity(colorScheme == .dark ? 0.14 : 0.08), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }
}

struct MeterGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func meterGlassCard(cornerRadius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(MeterTheme.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(MeterTheme.border))
        }
    }

    @ViewBuilder
    func meterProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func meterGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(MeterTheme.border))
        }
    }

    @ViewBuilder
    func meterGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(MeterTheme.panel, in: Circle())
                .overlay(Circle().stroke(MeterTheme.border))
        }
    }
}
