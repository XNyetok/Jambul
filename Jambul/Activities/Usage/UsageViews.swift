import SwiftUI

extension UsageActivity {
    var compactLeading: some View { EmptyView() }
    var compactTrailing: some View { EmptyView() }
    var tab: some View { UsageTab(activity: self) }
    var homeCard: some View { UsageHomeCard(activity: self) }
    /// Nothing to sum up with every subscription turned off.
    var showsHomeCard: Bool { !enabled.isEmpty }

    /// The color of a bar or a number: the subscription's own while there is room, then yellow, then red.
    static func color(for used: Double, provider: UsageProvider) -> Color {
        used >= 0.95 ? .red : used >= 0.8 ? .yellow : provider.brandColor
    }
}

/// A provider's local macOS app icon when installed, or Jambul's own squircle glyph badge for CLI-only setups.
struct UsageLogo: View {
    let provider: UsageProvider
    var size: CGFloat
    var onIsland = true

    var body: some View {
        Group {
            if let appIcon = ProviderIcon.image(for: provider) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProviderBadge(provider: provider, size: size, onIsland: onIsland)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(provider.displayName))
    }
}

/// Original macOS-style squircle badge with a clean geometric coding glyph for CLI-only providers.
private struct ProviderBadge: View {
    let provider: UsageProvider
    let size: CGFloat
    let onIsland: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(backgroundGradient)
            shape.strokeBorder(borderColor, lineWidth: max(0.5, size * 0.04))
            glyph
                .stroke(glyphColor, style: StrokeStyle(lineWidth: max(1.1, size * 0.115), lineCap: .round, lineJoin: .round))
                .padding(size * 0.23)
        }
    }

    private var backgroundGradient: LinearGradient {
        let colors: [Color] = switch provider {
        case .claude:
            [Color(red: 0.90, green: 0.52, blue: 0.39), Color(red: 0.77, green: 0.36, blue: 0.25)]
        case .antigravity:
            [Color(red: 0.36, green: 0.60, blue: 0.98), Color(red: 0.18, green: 0.42, blue: 0.90)]
        case .codex:
            onIsland
                ? [Color(white: 0.98), Color(white: 0.86)]
                : [Color(red: 0.20, green: 0.20, blue: 0.24), Color(red: 0.10, green: 0.10, blue: 0.13)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var borderColor: Color {
        if provider == .codex, onIsland { return .black.opacity(0.12) }
        return .white.opacity(0.22)
    }

    private var glyphColor: Color {
        provider == .codex && onIsland ? Color(white: 0.10) : .white
    }

    private var glyph: ProviderGlyphShape {
        ProviderGlyphShape(provider: provider)
    }
}

/// Minimal geometric glyphs for each provider, drawn in normalized coordinates so they stay crisp from 12pt to 28pt.
private struct ProviderGlyphShape: Shape {
    let provider: UsageProvider

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        switch provider {
        case .claude:
            // Crisp 6-ray geometric asterisk (3 intersecting lines at 60° intervals).
            let r = min(w, h) * 0.48
            for i in 0..<3 {
                let angle = Double(i) * .pi / 3.0 - .pi / 2.0
                let dx = CGFloat(cos(angle)) * r
                let dy = CGFloat(sin(angle)) * r
                path.move(to: CGPoint(x: cx - dx, y: cy - dy))
                path.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
            }
        case .antigravity:
            // Ascending chevron with a subtle floating base bar.
            path.move(to: CGPoint(x: rect.minX + w * 0.14, y: rect.minY + h * 0.68))
            path.addLine(to: CGPoint(x: cx, y: rect.minY + h * 0.14))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.14, y: rect.minY + h * 0.68))
            path.move(to: CGPoint(x: rect.minX + w * 0.30, y: rect.minY + h * 0.88))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.30, y: rect.minY + h * 0.88))
        case .codex:
            // Classic terminal prompt `>_`.
            path.move(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.22))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: cy))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.maxY - h * 0.22))
            path.move(to: CGPoint(x: rect.minX + w * 0.56, y: rect.maxY - h * 0.22))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.maxY - h * 0.22))
        }
        return path
    }
}

/// The usage limits' card on Home: each subscription the owner turned on, with its logo and its fullest limit, yellow
/// from 80% and red from 95% as on the tab. Three leave no room for the card's name, which gives way to them, as the
/// tab's large numbers do. Like the tab, it asks for numbers that are old as it appears.
private struct UsageHomeCard: View {
    let activity: UsageActivity

    var body: some View {
        let now = activity.currentDate
        let providers = activity.enabled
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(providers, id: \.self) { provider in
                    HStack(spacing: 6) {
                        UsageLogo(provider: provider, size: 14)
                        percent(provider, now: now)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
            if providers.count < 3 {
                Spacer(minLength: 0)
                Text("Usage")
                    .font(HomeCardStyle.labelFont)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { activity.tabDidAppear() }
    }

    @ViewBuilder private func percent(_ provider: UsageProvider, now: Date) -> some View {
        if let used = activity.readings[provider]?.fullest(at: now)?.used(at: now) {
            Text(UsageActivity.percentText(used))
                .foregroundStyle(used >= 0.8 ? UsageActivity.color(for: used, provider: provider) : .white)
                .contentTransition(Motion.numberTransition(value: used))
                .animation(Motion.valueChange, value: UsageActivity.percentText(used))
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        }
    }
}

/// One column per subscription the owner turned on: its logo, its name and when it starts over, its fullest limit in
/// large type, and a bar for each limit.
struct UsageTab: View {
    let activity: UsageActivity

    var body: some View {
        let providers = activity.enabled
        // From the top, so a subscription with fewer limits keeps its logo and name in line with the others'.
        HStack(alignment: .top, spacing: 14) {
            if providers.isEmpty {
                Text("Turn on a subscription in Settings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                UsageColumn(activity: activity, provider: provider, index: index, showsTotal: providers.count < 3)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { activity.tabDidAppear() }
    }
}

private struct UsageColumn: View {
    let activity: UsageActivity
    let provider: UsageProvider
    let index: Int
    let showsTotal: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandIsVisible) private var isVisible
    @State private var appeared = false
    @State private var workingTurns = 0

    private var now: Date { activity.currentDate }
    private var reading: UsageReading? { activity.readings[provider] }
    private var fullest: UsageWindow? { reading?.fullest(at: now) }
    /// Claude's logo turns a step on each beat while Claude Code works, only while the open island shows it; between
    /// steps nothing moves, as with Keep Awake's eyes.
    private var turnsWhileWorking: Bool { provider == .claude && isVisible && !reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                logo
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    detail
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if showsTotal, let fullest {
                    let used = fullest.used(at: now)
                    Text(UsageActivity.percentText(used))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(used >= 0.8 ? UsageActivity.color(for: used, provider: provider) : .white)
                        .monospacedDigit()
                        .contentTransition(Motion.numberTransition(value: used))
                        .animation(Motion.valueChange, value: UsageActivity.percentText(used))
                        .offset(y: appeared || reduceMotion ? 0 : Motion.Usage.riseFrom)
                        .opacity(appeared ? 1 : 0)
                }
            }
            VStack(spacing: 6) {
                ForEach(Array(bars.enumerated()), id: \.offset) { offset, window in
                    UsageBar(window: window, provider: provider, now: now, shown: appeared, delay: barDelay(offset))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(reduceMotion ? Motion.Usage.reducedFade : Motion.Usage.pop.delay(stagger)) { appeared = true }
        }
        .task(id: turnsWhileWorking) {
            guard turnsWhileWorking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Motion.Usage.untilNextBeat())
                if activity.isClaudeWorking {
                    withAnimation(Motion.Usage.workingStep) { workingTurns += 1 }
                }
            }
        }
    }

    private var stagger: Double { Double(index) * Motion.Usage.popStagger }

    private func barDelay(_ offset: Int) -> Double { stagger + Double(offset) * Motion.Usage.fillStagger }

    /// Each limit once; Antigravity's buckets come down to the fullest five-hour and weekly ones.
    private var bars: [UsageWindow] {
        guard let reading else { return [] }
        guard provider == .antigravity else { return reading.windows }
        return Dictionary(grouping: reading.windows, by: \.label)
            .compactMap { _, windows in windows.max { $0.used(at: now) < $1.used(at: now) } }
            .sorted { $0.label < $1.label }
    }

    /// The provider icon popping in, with a subtle activity ring around it while Claude Code works.
    private var logo: some View {
        ZStack {
            UsageLogo(provider: provider, size: 28)
            if provider == .claude, activity.isClaudeWorking {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(provider.brandColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90 + Double(workingTurns) * Motion.Usage.workingStepAngle))
            }
        }
        .scaleEffect(appeared || reduceMotion ? 1 : Motion.Usage.popScale)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder private var detail: some View {
        if activity.needsConnecting.contains(provider) {
            Button("Connect") { activity.onConnect?(provider) }
                .buttonStyle(.islandProminent(tint: provider.brandColor))
                .controlSize(.small)
        } else {
            Text(detailText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var detailText: String {
        if let problem = activity.problems[provider], reading == nil || provider == .codex { return problem }
        guard let reading, let fullest else { return String(localized: "No numbers yet") }
        if fullest.hasReset(at: now) { return String(localized: "limit reset") }
        if now.timeIntervalSince(reading.measuredAt) > 30 * 60, provider != .claude {
            return reading.measuredAt.formatted(.relative(presentation: .named))
        }
        return fullest.resetsAt.map { UsageActivity.resetText($0, now: now) } ?? ""
    }
}

/// One limit: its length, a thin bar filling to how much is used, and the percentage.
private struct UsageBar: View {
    let window: UsageWindow
    let provider: UsageProvider
    let now: Date
    let shown: Bool
    let delay: Double

    var body: some View {
        let used = window.used(at: now)
        let color = UsageActivity.color(for: used, provider: provider)
        HStack(spacing: 7) {
            Text(window.label)
                .frame(width: 16, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.14))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * (shown ? max(used, 0.03) : 0))
                            .animation(Motion.Usage.fill.delay(delay), value: shown)
                            .animation(Motion.valueChange, value: used)
                    }
            }
            .frame(height: 4)
            Text(UsageActivity.percentText(used))
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(used >= 0.8 ? color : .secondary)
                .monospacedDigit()
                .contentTransition(Motion.numberTransition(value: used))
                .animation(Motion.valueChange, value: UsageActivity.percentText(used))
        }
        .font(.system(size: 10, weight: .semibold))
        .accessibilityElement(children: .combine)
    }
}
