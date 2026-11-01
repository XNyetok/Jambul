import AppKit
import AVFoundation
import os

/// The taps and sounds Jambul plays.
@MainActor
enum Feedback {
    /// The sounds macOS ships in /System/Library/Sounds ("Glass", "Hero", …), by name.
    static let systemSounds: [String: URL] = {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(files.map { ($0.deletingPathExtension().lastPathComponent, $0) }) { first, _ in first }
    }()

    static let systemSoundNames = systemSounds.keys.sorted()

    private static let sounds = SoundPlayer()

    /// Taps on the trackpad, felt only by a finger resting on it. A single tap gets lost in the feel of a finger
    /// sliding across the trackpad, so it can play as a short run.
    static func playTaps(_ count: Int) {
        guard count > 0 else { return }
        Task {
            for tap in 0..<count {
                if tap > 0 { try? await Task.sleep(for: Motion.hapticTapSpacing, tolerance: Motion.timerTolerance) }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    /// Plays one of `systemSounds` from its start, cutting off whatever played before; nil just stops it. Loaded from
    /// the file rather than by name, since a sound by the same name in ~/Library/Sounds would win the lookup.
    static func play(_ name: String?) {
        sounds.play(name.flatMap { name in systemSounds[name].map { (name, $0) } })
    }
}

/// Plays sounds on a queue of its own. The first sound after launch spends 66–218 ms setting up audio (measured), and
/// on the main thread that stalled the "Timer done" peek as it opened; off it, the main thread is free within 0.2 ms.
final class SoundPlayer: @unchecked Sendable {
    /// Loads a sound and starts it, returning its player, or nil if it didn't start.
    typealias Start = @Sendable (URL) throws -> AVAudioPlayer?

    private let queue = DispatchQueue(label: "com.debikurnia.Jambul.sound", qos: .userInitiated)
    private let start: Start
    /// The sound playing now, only touched on `queue`. Releasing a player stops it, so it is kept until the next one.
    private var player: AVAudioPlayer?

    /// - Parameter start: Loads and starts a sound; tests stand in for it rather than make a sound.
    init(start: @escaping Start = SoundPlayer.startPlaying) {
        self.start = start
    }

    func play(_ sound: (name: String, url: URL)?) {
        queue.async { [self] in
            player?.stop()
            player = nil
            guard let sound else { return }
            do {
                player = try start(sound.url)
                if player == nil { Logger.app.error("sound \(sound.name, privacy: .public) didn't play") }
            } catch {
                Logger.app.error("""
                    sound \(sound.name, privacy: .public) didn't load: \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    static func startPlaying(_ url: URL) throws -> AVAudioPlayer? {
        let player = try AVAudioPlayer(contentsOf: url)
        return player.play() ? player : nil
    }
}
