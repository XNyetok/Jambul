import AppKit

/// Tells whether a screen is showing a full-screen Space. macOS has no public API for this, so it looks up
/// SkyLight's private functions once; if they ever go away, every Space reads as a regular desktop.
///
/// Window-list heuristics were tried first and proved unreliable: full-screen windows look like zoomed ones,
/// and the system windows that differ between the two come and go.
struct SpaceInspector {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32

    /// SkyLight's type for a full-screen or split-view Space; regular desktops are 0.
    private static let fullScreenType: Int32 = 4

    private let mainConnection: MainConnection?
    private let currentSpace: CurrentSpace?
    private let spaceType: SpaceType?

    init() {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func lookUp<Function>(_ name: String, as _: Function.Type) -> Function? {
            guard let skyLight, let symbol = dlsym(skyLight, name) else { return nil }
            return unsafeBitCast(symbol, to: Function.self)
        }
        mainConnection = lookUp("SLSMainConnectionID", as: MainConnection.self)
        currentSpace = lookUp("SLSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
        spaceType = lookUp("SLSSpaceGetType", as: SpaceType.self)
    }

    @MainActor
    func isShowingFullScreen(_ screen: NSScreen) -> Bool {
        guard let mainConnection, let currentSpace, let spaceType,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid)
        else { return false }
        let connection = mainConnection()
        return spaceType(connection, currentSpace(connection, uuidString)) == Self.fullScreenType
    }
}
