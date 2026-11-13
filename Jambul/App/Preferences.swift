import Foundation
import Observation

/// How quickly hovering the notch opens the island.
enum HoverSpeed: String, CaseIterable, Identifiable {
    case fast, normal, slow

    var id: Self { self }

    /// How long the pointer has to rest on the notch before the island opens. Past about 100 ms the wait reads as
    /// lag, so even the slow setting stays short; it only guards against passing over the notch on the way to the
    /// menu bar.
    var intent: Duration {
        switch self {
        case .fast: .zero
        case .normal: .milliseconds(60)
        case .slow: .milliseconds(150)
        }
    }
}

/// The owner's settings. Each change is saved to `UserDefaults` right away.
@MainActor
@Observable
final class Preferences {
    var hoverSpeed: HoverSpeed {
        didSet { save(hoverSpeed.rawValue, for: .hoverSpeed) }
    }

    /// Taps played on the trackpad as the pointer reaches the notch and when a timer ends; 0 turns them off.
    var hapticTaps: Int {
        didSet { save(hapticTaps, for: .hapticTaps) }
    }

    var hidesInFullScreen: Bool {
        didSet { save(hidesInFullScreen, for: .hidesInFullScreen) }
    }

    /// The sound a finished timer plays, one of `Feedback.systemSoundNames`, or nil for none.
    var timerSound: String? {
        didSet { save(timerSound ?? "", for: .timerSound) }
    }

    static let defaultTimerSound = "Glass"

    /// The subscriptions whose usage limits the island shows.
    var usageProviders: Set<UsageProvider> {
        didSet { save(usageProviders.map(\.rawValue).sorted(), for: .usageProviders) }
    }

    /// Whether the owner agreed to connect Claude Code's status line, which changes Claude Code's settings. Claude's
    /// limits only reach Jambul through it.
    var claudeStatusLineAgreed: Bool {
        didSet { save(claudeStatusLineAgreed, for: .claudeStatusLineAgreed) }
    }

    /// Whether the island follows Claude Code's sessions, through hooks the owner agreed to add to Claude Code's
    /// settings. Turning it off takes them out again.
    var showsAgentSessions: Bool {
        didSet { save(showsAgentSessions, for: .showsAgentSessions) }
    }

    /// Called after any setting changes.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverSpeed = defaults.string(forKey: Key.hoverSpeed.rawValue).flatMap(HoverSpeed.init(rawValue:)) ?? .normal
        hapticTaps = min(max(defaults.object(forKey: Key.hapticTaps.rawValue) as? Int ?? 2, 0), 3)
        hidesInFullScreen = defaults.bool(forKey: Key.hidesInFullScreen.rawValue)
        // Saved as an empty string when off. A sound that's no longer on the system falls back to the default.
        timerSound = switch defaults.string(forKey: Key.timerSound.rawValue) {
        case "": nil
        case let name? where Feedback.systemSounds[name] != nil: name
        default: Self.defaultTimerSound
        }
        usageProviders = (defaults.stringArray(forKey: Key.usageProviders.rawValue))
            .map { Set($0.compactMap(UsageProvider.init(rawValue:))) }
            ?? Set(UsageProvider.allCases.filter(\.isOnByDefault))
        claudeStatusLineAgreed = defaults.bool(forKey: Key.claudeStatusLineAgreed.rawValue)
        showsAgentSessions = defaults.bool(forKey: Key.showsAgentSessions.rawValue)
    }

    private enum Key: String {
        case hoverSpeed, hapticTaps, hidesInFullScreen, timerSound, usageProviders, claudeStatusLineAgreed
        case showsAgentSessions
    }

    private func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        onChange?()
    }
}
