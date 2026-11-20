import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var loginItem: LoginItem
    var usage: UsageActivity?
    var agent: AgentActivity?
    @State private var confirmingClaude = false
    @State private var confirmingSessions: UsageProvider?
    /// Whether the question about connecting Claude came from turning it on, so No turns it off again.
    @State private var confirmingFromToggle = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $loginItem.isEnabled)
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
                    Text("Hover speed")
                    Text("Fast opens the moment the pointer reaches the notch. Slow waits a beat, for when you often pass over it on the way to the menu bar.")
                }
                .pickerStyle(.segmented)
                Picker(selection: $preferences.hapticTaps) {
                    Text("Off").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                } label: {
                    Text("Haptic taps")
                    Text("Taps on the trackpad as the pointer reaches the notch and when a timer ends. Felt only by a finger resting on a Force Touch trackpad, not with a mouse.")
                }
                .pickerStyle(.segmented)
                Toggle("Hide while an app is full screen", isOn: $preferences.hidesInFullScreen)
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
                    Text("Sound when a timer ends")
                    Text("Each sound plays as you pick it.")
                }
                .onChange(of: preferences.timerSound) { _, sound in
                    Feedback.play(sound)
                }
            }

            Section {
                ForEach(UsageProvider.sessionProviders, id: \.self) { provider in
                    Toggle(isOn: showsSessions(provider)) {
                        Text(provider.sessionName)
                        Text(sessionsStatus(provider))
                    }
                }
            } header: {
                Text("Coding sessions")
            } footer: {
                Text("Shows when a session works, needs you or is done, and lets Keep Awake stay on until it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(UsageProvider.allCases, id: \.self) { provider in
                    Toggle(isOn: isOn(provider)) {
                        HStack(spacing: 10) {
                            UsageLogo(provider: provider, size: 18, onIsland: false)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(status(provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if provider == .claude, needsConnectingClaude {
                        LabeledContent("Claude’s limits arrive once its status line is connected.") {
                            Button("Connect…") {
                                confirmingFromToggle = false
                                confirmingClaude = true
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Usage limits")
            } footer: {
                Text("Jambul doesn’t use the internet. Antigravity’s numbers come from agy, which asks Google.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsView {
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
            return agent?.codexRuntimeAvailable == true
                ? String(localized: "Shared runtime connected · review new hooks in /hooks")
                : String(localized: "Hooks installed · review in /hooks, then start a local session")
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
        guard isOn(provider).wrappedValue else {
            return switch provider {
            case .claude: String(localized: "Off · reads Claude Code’s status line")
            case .antigravity: String(localized: "Off · asks agy for its usage report")
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

#if DEBUG
#Preview {
    SettingsView(preferences: Preferences(defaults: UserDefaults(suiteName: "JambulPreview") ?? .standard),
                 loginItem: LoginItem())
}
#endif
