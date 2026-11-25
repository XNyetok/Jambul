import ServiceManagement
import SwiftUI

/// The Settings window's panes, one tab each in its toolbar.
enum SettingsPane: Int, CaseIterable {
    case general, aiTools

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .aiTools: String(localized: "AI Tools")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .aiTools: "sparkles"
        }
    }
}

/// Both panes are as wide, so changing tabs only changes how tall the window is.
enum SettingsLayout {
    static let width: CGFloat = 460
}

/// How Jambul starts, how the island answers the pointer, and what a timer sounds like.
struct GeneralSettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var loginItem: LoginItem

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $loginItem.isEnabled) {
                    Label {
                        Text("Open at login")
                    } icon: {
                        Image(systemName: "power")
                            .frame(width: SettingsLabel.symbolWidth)
                    }
                }
                if loginItem.needsApproval {
                    LabeledContent("Waiting for your approval in System Settings.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.secondary)
                }
                if let failure = loginItem.failure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
            Section("Island") {
                Picker(selection: $preferences.hoverSpeed) {
                    Text("Fast").tag(HoverSpeed.fast)
                    Text("Normal").tag(HoverSpeed.normal)
                    Text("Slow").tag(HoverSpeed.slow)
                } label: {
                    SettingsLabel("Hover speed", symbol: "cursorarrow.motionlines",
                                  detail: Text("How long the pointer rests on the notch first."))
                }
                .pickerStyle(.segmented)
                Picker(selection: $preferences.hapticTaps) {
                    Text("Off").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                } label: {
                    SettingsLabel("Haptic taps", symbol: "hand.tap",
                                  detail: Text("Felt on a Force Touch trackpad at the notch and as a timer ends."))
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $preferences.hidesInFullScreen) {
                    SettingsLabel("Hide in full screen", symbol: "arrow.up.left.and.arrow.down.right",
                                  detail: Text("News you must see, like a timer ending, still shows."))
                }
            }
            Section("Timer") {
                LabeledContent {
                    HStack {
                        Picker("Sound when a timer ends", selection: $preferences.timerSound) {
                            Text("Off").tag(String?.none)
                            Divider()
                            ForEach(Feedback.systemSoundNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        // Picking the sound that's already chosen changes nothing, so it can't play; this can.
                        Button {
                            Feedback.play(preferences.timerSound)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .labelStyle(.iconOnly)
                        }
                        .help("Play the sound")
                        .disabled(preferences.timerSound == nil)
                    }
                } label: {
                    SettingsLabel("Sound when it ends", symbol: "bell", detail: Text("Each sound plays as you pick it."))
                }
                .onChange(of: preferences.timerSound) { _, sound in
                    Feedback.play(sound)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One group per AI tool, each holding the two things Jambul can show for it: how much of its plan is left, and its
/// coding sessions. Side by side, the two switches for one tool can't be mistaken for another tool's.
struct AIToolsSettingsView: View {
    @Bindable var preferences: Preferences
    var usage: UsageActivity?
    var agent: AgentActivity?
    @State private var confirmingClaude = false
    @State private var confirmingSessions: UsageProvider?
    /// Whether the question about connecting Claude came from turning it on, so No turns it off again.
    @State private var confirmingFromToggle = false

    static let tools: [UsageProvider] = [.claude, .codex, .antigravity]

    var body: some View {
        Form {
            ForEach(Self.tools, id: \.self) { provider in
                Section {
                    Toggle(isOn: isOn(provider)) {
                        SettingsLabel("Usage limits", symbol: "gauge.with.dots.needle.33percent",
                                      detail: Text(status(provider)))
                    }
                    .disabled(!provider.supportsUsageLimits)
                    if provider == .claude, needsConnectingClaude {
                        LabeledContent("Claude’s limits arrive once its status line is connected.") {
                            Button("Connect…") {
                                confirmingFromToggle = false
                                confirmingClaude = true
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: showsSessions(provider)) {
                        SettingsLabel("Coding sessions", symbol: "chevron.left.forwardslash.chevron.right",
                                      detail: Text(sessionsStatus(provider)))
                    }
                } header: {
                    HStack(spacing: 8) {
                        UsageLogo(provider: provider, size: 16, onIsland: false)
                        Text(provider.displayName)
                    }
                } footer: {
                    if provider == Self.tools.last {
                        Text("Coding sessions show when an agent works, needs you or is done, and let Keep Awake stay on until it finishes. Jambul itself makes no network connections; Codex usage comes from the local Codex CLI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Connect Claude?", isPresented: $confirmingClaude) {
            Button("Connect") {
                preferences.claudeStatusLineAgreed = true
                preferences.usageProviders.insert(.claude)
            }
            Button("Cancel", role: .cancel) {
                if confirmingFromToggle { preferences.usageProviders.remove(.claude) }
            }
        } message: {
            Text("Jambul adds itself to Claude Code’s status line in ~/.claude/settings.json to read your usage limits. Your status line looks the same, and turning Claude off puts it back exactly as it was.")
        }
        .alert("Connect coding sessions?", isPresented: Binding(
            get: { confirmingSessions != nil }, set: { if !$0 { confirmingSessions = nil } }
        ), presenting: confirmingSessions) { provider in
            Button("Connect") { preferences.agentProviders.insert(provider) }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text(sessionConsent(provider))
        }
        .frame(width: SettingsLayout.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension AIToolsSettingsView {
    /// Whether a subscription shows in the island. Claude also needs its status line connected, which the owner is
    /// asked about as they turn it on, and can do later with Connect; turning it off disconnects it.
    private func isOn(_ provider: UsageProvider) -> Binding<Bool> {
        Binding {
            preferences.usageProviders.contains(provider)
        } set: { on in
            if on {
                preferences.usageProviders.insert(provider)
                if provider == .claude, !preferences.claudeStatusLineAgreed {
                    confirmingFromToggle = true
                    confirmingClaude = true
                }
            } else {
                if provider == .claude { preferences.claudeStatusLineAgreed = false }
                preferences.usageProviders.remove(provider)
            }
        }
    }

    /// Asks before adding the hooks; turning it off takes them out.
    private func showsSessions(_ provider: UsageProvider) -> Binding<Bool> {
        Binding {
            preferences.agentProviders.contains(provider)
        } set: { on in
            if on { confirmingSessions = provider } else { preferences.agentProviders.remove(provider) }
        }
    }

    private func sessionsStatus(_ provider: UsageProvider) -> String {
        if let problem = agent?.problems[provider] { return problem }
        guard preferences.agentProviders.contains(provider) else { return String(localized: "Off") }
        switch provider {
        case .claude:
            return String(localized: "Connected · sessions you start from now on show")
        case .codex:
            return String(localized: "Connected · approve Jambul’s hooks in Codex’s /hooks if it asks")
        case .antigravity:
            return String(localized: "Connected · reopen agy to pick up the hooks and status line")
        }
    }

    private func sessionConsent(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude:
            String(localized: "Jambul adds its hooks to ~/.claude/settings.json. Other hooks keep running, and turning sessions off removes Jambul’s hooks.")
        case .codex:
            String(localized: "Jambul adds its own local Codex hooks. Review them in /hooks before they can run. Jambul reads session status from the shared local runtime when it’s available.")
        case .antigravity:
            String(localized: "Jambul adds a group to ~/.gemini/config/hooks.json and joins agy’s status line to see when an approval dialog is open. Your status line stays visible, and turning sessions off restores its settings.")
        }
    }

    private var needsConnectingClaude: Bool {
        preferences.usageProviders.contains(.claude) && !preferences.claudeStatusLineAgreed
    }

    private func status(_ provider: UsageProvider) -> String {
        guard provider.supportsUsageLimits else {
            return String(localized: "Paused · headless agy usage checks are disabled")
        }
        guard isOn(provider).wrappedValue else {
            return switch provider {
            case .claude: String(localized: "Off · reads Claude Code’s status line")
            case .antigravity: String(localized: "Paused · headless agy usage checks are disabled")
            case .codex: String(localized: "Off · asks the Codex CLI for account usage")
            }
        }
        if provider == .claude, !preferences.claudeStatusLineAgreed { return String(localized: "Not connected") }
        if let problem = usage?.problems[provider] { return problem }
        if usage?.readings[provider] != nil { return String(localized: "Connected") }
        return switch provider {
        case .claude: String(localized: "Connected · numbers arrive with Claude Code’s next reply")
        case .antigravity: String(localized: "Waiting for agy")
        case .codex: String(localized: "Waiting for Codex usage")
        }
    }
}

/// A setting's name with its symbol, and a line under it saying what it does or how it stands.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let detail: Text
    static let symbolWidth: CGFloat = 20

    init(_ title: LocalizedStringKey, symbol: String, detail: Text) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
    }

    var body: some View {
        Label {
            Text(title)
            detail
        } icon: {
            // As wide for every symbol, so the names line up.
            Image(systemName: symbol)
                .frame(width: Self.symbolWidth)
        }
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettingsView(preferences: Preferences(defaults: UserDefaults(suiteName: "JambulPreview") ?? .standard),
                        loginItem: LoginItem())
}

#Preview("AI Tools") {
    AIToolsSettingsView(preferences: Preferences(defaults: UserDefaults(suiteName: "JambulPreview") ?? .standard))
}
#endif
