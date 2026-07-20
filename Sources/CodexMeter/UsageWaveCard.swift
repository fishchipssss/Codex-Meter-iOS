import SwiftUI
import CodexMeterCore

struct UsageWaveCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let symbol: String
    let window: UsageWindow?
    let isConnected: Bool
    let colors: [Color]
    let waveOffset: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let window {
                    WaveShape(level: CGFloat(window.remainingPercent) / 100, phase: waveOffset)
                        .fill(LinearGradient(colors: colors.map { $0.opacity(waveOpacity) }, startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(title, systemImage: symbol)
                            .font(.headline)
                            .foregroundStyle(primaryText)
                        Text(resetText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(window.map { "\($0.remainingPercent)%" } ?? "—")
                            .font(.system(size: 35, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(primaryText)
                        Text("LEFT")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.2)
                            .foregroundStyle(tertiaryText)
                    }
                }
                .padding(.horizontal, 20)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .meterGlassCard(cornerRadius: 25)
        }
        .frame(height: 112)
    }

    private var waveOpacity: Double {
        if #available(iOS 26.0, *) { 0.38 } else { 0.72 }
    }

    private var primaryText: Color {
        if #available(iOS 26.0, *) {
            return colorScheme == .dark ? .white : Color(uiColor: .label)
        }
        return window == nil ? .primary : .white
    }

    private var secondaryText: Color {
        if #available(iOS 26.0, *) {
            return colorScheme == .dark ? .white.opacity(0.82) : Color(uiColor: .secondaryLabel)
        }
        return window == nil ? MeterTheme.secondary : .white.opacity(0.76)
    }

    private var tertiaryText: Color {
        if #available(iOS 26.0, *) {
            return colorScheme == .dark ? .white.opacity(0.68) : Color(uiColor: .tertiaryLabel)
        }
        return window == nil ? MeterTheme.tertiary : .white.opacity(0.62)
    }

    private var resetText: String {
        guard isConnected else { return "Not connected" }
        guard let date = window?.resetDate else { return "Waiting for data" }
        return "Resets \(date.formatted(.relative(presentation: .numeric)))"
    }
}

private struct WaveShape: Shape {
    let level: CGFloat
    let phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let clamped = max(0.08, min(0.92, level))
        let baseline = rect.height * (1 - clamped)
        let amplitude: CGFloat = 9
        path.move(to: CGPoint(x: 0, y: baseline))
        for x in stride(from: CGFloat(0), through: rect.width, by: 3) {
            let progress = x / max(1, rect.width)
            let y = baseline + sin(progress * .pi * 2.2 + phase) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
