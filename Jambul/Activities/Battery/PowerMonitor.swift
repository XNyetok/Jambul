import Foundation
import IOKit.ps

/// What the battery reports: the charge the menu bar shows and whether the Mac is plugged in.
struct PowerState: Equatable, Sendable {
    /// The percentage the menu bar shows, 0 to 100.
    var percent: Int
    /// Plugged into power. macOS reports this the moment the charger connects, but only says it is charging up to a
    /// minute later (measured), so this, not charging, tells plugging in from unplugging.
    var isOnExternalPower: Bool
}

/// Reports the internal battery through IOKit's power-source notification, which macOS posts when the charge or the
/// power source changes: about once a minute on battery, and at once on plugging in (measured). No polling, and no
/// permission needed.
@MainActor
final class PowerMonitor {
    /// Each reading as it comes, starting with the current one; nil on a Mac without a battery.
    var onChange: (@MainActor (PowerState?) -> Void)?
    private var source: CFRunLoopSource?

    /// The app keeps the monitor for its whole life, so it never needs to stop.
    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // A C callback can't capture anything, so the monitor rides along as its context. It runs on the main run loop.
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().report()
            }
        }, context)?.takeRetainedValue() else { return }
        // Common modes, so readings still arrive while the status item's menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        report()
    }

    private func report() {
        onChange?(Self.read())
    }

    /// The internal battery, if there is one; a UPS isn't it.
    nonisolated static func read() -> PowerState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool == true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return PowerState(percent: min(max(current * 100 / maximum, 0), 100),
                              isOnExternalPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}
