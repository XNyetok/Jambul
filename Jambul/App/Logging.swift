import Foundation
import os

extension Logger {
    /// Island presentation and visibility changes. Read them back with
    /// `/usr/bin/log show --last 10m --predicate 'subsystem == "com.debikurnia.Jambul"'`.
    static let island = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Jambul", category: "island")
    /// App-level events such as login item changes.
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Jambul", category: "app")
    /// What activities do: a timer starting, pausing, finishing.
    static let activities = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Jambul", category: "activities")
}
