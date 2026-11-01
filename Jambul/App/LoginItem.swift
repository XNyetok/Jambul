import Observation
import os
import ServiceManagement

/// Jambul's login item, as the system sees it.
@MainActor
@Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var failure: String?

    /// On once registered, including while macOS still waits for approval in System Settings.
    var isEnabled: Bool {
        get { status == .enabled || status == .requiresApproval }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                failure = nil
            } catch {
                failure = error.localizedDescription
                Logger.app.error("login item \(newValue ? "register" : "unregister", privacy: .public) failed: \(error)")
            }
            refresh()
        }
    }

    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }
}
