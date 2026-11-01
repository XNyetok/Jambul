import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var loginItem: LoginItem

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
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview {
    SettingsView(preferences: Preferences(defaults: UserDefaults(suiteName: "JambulPreview") ?? .standard),
                 loginItem: LoginItem())
}
#endif
