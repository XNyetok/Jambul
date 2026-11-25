import AppKit
import Foundation

/// Resolves an AI provider's icon from an application already installed on this Mac, without bundling third-party
/// artwork in Jambul. Results are cached for the process lifetime so views never hit disk while animating.
@MainActor
enum ProviderIcon {
    private static var cache: [UsageProvider: NSImage?] = [:]

    static func image(for provider: UsageProvider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let resolved = resolve(for: provider)
        cache[provider] = resolved
        return resolved
    }

    /// Resolves the icon using injectable lookups for unit tests.
    static func resolve(
        for provider: UsageProvider,
        urlForBundleID: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        iconForFile: (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) -> NSImage? {
        for bundleID in provider.localAppBundleIdentifiers {
            if let url = urlForBundleID(bundleID) {
                return iconForFile(url.path)
            }
        }
        for path in provider.localAppPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fileExists(expanded) {
                return iconForFile(expanded)
            }
        }
        return nil
    }
}

extension UsageProvider {
    /// Bundle identifiers of local macOS apps whose system icon can represent this provider.
    var localAppBundleIdentifiers: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .antigravity: ["com.google.antigravity", "com.google.Antigravity"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        }
    }

    /// Fallback `.app` locations checked if Launch Services doesn't return a bundle match.
    var localAppPaths: [String] {
        switch self {
        case .claude: ["/Applications/Claude.app", "~/Applications/Claude.app"]
        case .antigravity: ["/Applications/Antigravity.app", "~/Applications/Antigravity.app"]
        case .codex: [
            "/Applications/Codex.app", "~/Applications/Codex.app",
            "/Applications/ChatGPT.app", "~/Applications/ChatGPT.app",
        ]
        }
    }
}
