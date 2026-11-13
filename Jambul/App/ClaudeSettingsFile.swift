import Foundation

/// Claude Code's settings, ~/.claude/settings.json, which Jambul joins through its status line and its hooks. A symbolic
/// link is followed, so a dotfiles setup keeps working.
struct ClaudeSettingsFile {
    let url: URL

    enum Failure: Error, Equatable {
        /// The settings aren't JSON Jambul can read, so it leaves them alone.
        case unreadableSettings
    }

    /// The file to read and write: the settings, or what their link points to.
    private var file: URL { url.resolvingSymlinksInPath() }

    /// The settings, or none if there is no file or only blank space in it.
    func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return settings
    }

    /// Writes the settings in one step, after keeping the first version Jambul ever changed. Settings Jambul created
    /// and emptied again are removed rather than left behind as `{}`.
    func write(_ settings: [String: Any]) throws {
        let fileManager = FileManager.default
        let backup = url.appendingPathExtension("jambul-backup")
        let existed = fileManager.fileExists(atPath: file.path)
        if settings.isEmpty, !fileManager.fileExists(atPath: backup.path) {
            if existed { try fileManager.removeItem(at: file) }
            return
        }
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existed, !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: file, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
    }
}
