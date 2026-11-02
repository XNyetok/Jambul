import SwiftUI

extension UsageActivity {
    /// The logo of the subscription nearest its limit.
    var compactLeading: some View { UsageCompactLogo(activity: self) }
    /// Its percentage, or once it has run out, the time until it starts over.
    var compactTrailing: some View { UsageCompactValue(activity: self) }
    var compactMinimal: AnyView { AnyView(UsageCompactLogo(activity: self)) }
    var tab: some View { UsageTab(activity: self) }
    var homeCard: some View { UsageHomeCard(activity: self) }
    /// Nothing to sum up with every subscription turned off.
    var showsHomeCard: Bool { !enabled.isEmpty }

    /// The time left until a limit starts over, short enough for beside the notch: "45m", "9h59", "12h", "1d6h", "20d".
    /// Each unit is rounded up, as a wait is.
    static func countdown(_ remaining: TimeInterval) -> String {
        let minutes = Int((max(remaining, 0) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 10 * 60 { return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" }
        let hours = Int((Double(minutes) / 60).rounded(.up))
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24, rest = hours % 24
        if days < 10 { return rest > 0 ? "\(days)d\(rest)h" : "\(days)d" }
        return "\(Int((Double(hours) / 24).rounded(.up)))d"
    }

    /// The color of a bar or a number: the subscription's own while there is room, then yellow, then red.
    static func color(for used: Double, provider: UsageProvider) -> Color {
        used >= 0.95 ? .red : used >= 0.8 ? .yellow : provider.brandColor
    }
}

/// A subscription's logo, which no color or shape of Jambul's changes. OpenAI's comes in black or white, so it takes the
/// color of the text around it: white on the island, black in a light Settings window.
struct UsageLogo: View {
    let provider: UsageProvider
    var size: CGFloat
    var onIsland = true

    var body: some View {
        Image(provider.logoAsset)
            .resizable()
            .renderingMode(provider == .codex ? .template : .original)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(onIsland ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .accessibilityLabel(Text(provider.displayName))
    }
}

private struct UsageCompactLogo: View {
    let activity: UsageActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0

    var body: some View {
        if let provider = activity.pressing?.provider {
            UsageLogo(provider: provider, size: IslandLayout.compactGlyphHeight)
                .phaseAnimator(reduceMotion ? [1] : Motion.Usage.pulseScales, trigger: beat) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in Motion.Usage.beat }
                .onAppear { beat += 1 }
        }
    }
}

private struct UsageCompactValue: View {
    let activity: UsageActivity
    @Environment(\.islandIsVisible) private var isVisible

    var body: some View {
        if let window = activity.pressing?.window {
            if window.used >= 1, let resetsAt = window.resetsAt {
                // Once a minute, and only while someone can see it.
                TimelineView(.periodic(from: .now, by: isVisible ? 60 : 3_600)) { context in
                    label(UsageActivity.countdown(resetsAt.timeIntervalSince(context.date)))
                }
            } else {
                label(UsageActivity.percentText(window.used))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.red)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
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
        HStack(spacing: 14) {
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
    /// steps nothing moves, as with Keep Awake's eye.
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
                try? await Task.sleep(for: .seconds(Motion.Usage.workingBeat))
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

    /// The logo popping in. Antigravity's also rises past its place and settles, on an animation of its own that
    /// touches only the rise, so the pop reaches every logo.
    private var logo: some View {
        UsageLogo(provider: provider, size: 28)
            .offset(y: provider == .antigravity && !appeared && !reduceMotion ? Motion.Usage.floatFrom : 0)
            .animation(provider == .antigravity ? Motion.Usage.float.delay(stagger) : nil, value: appeared)
            .rotationEffect(.degrees(logoTurn))
            .scaleEffect(appeared || reduceMotion ? 1 : Motion.Usage.popScale)
            .opacity(appeared ? 1 : 0)
    }

    private var logoTurn: Double {
        guard provider == .claude, !reduceMotion else { return 0 }
        return (appeared ? 0 : Motion.Usage.turnFrom) + Double(workingTurns) * Motion.Usage.workingStepAngle
    }

    @ViewBuilder private var detail: some View {
        if activity.needsConnecting.contains(provider) {
            Button("Connect") { activity.onConnect?(provider) }
                .buttonStyle(.island(tint: provider.brandColor))
                .controlSize(.small)
        } else {
            Text(detailText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var detailText: String {
        if let problem = activity.problems[provider], reading == nil { return problem }
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
                    }
            }
            .frame(height: 4)
            Text(UsageActivity.percentText(used))
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(used >= 0.8 ? color : .secondary)
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .semibold))
        .accessibilityElement(children: .combine)
    }
}
