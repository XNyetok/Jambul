import AppKit

if CommandLine.arguments.dropFirst().first == SessionRelay.flag {
    SessionRelay.send(Array(CommandLine.arguments.dropFirst(2)))
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
