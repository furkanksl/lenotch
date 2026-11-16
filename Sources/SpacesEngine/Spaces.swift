import AppKit

/// Optional SkyLight functions. Keep the framework open for the lifetime of its function pointers.
private enum SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyManagedDisplays = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?
    typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    typealias SetCurrentSpace = @convention(c) (Int32, CFString, UInt64) -> Void
    typealias CopyDisplay = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
    typealias CornerRadius = @convention(c) (UInt32) -> Double

    static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    static let copyManagedDisplays = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplays.self)
    static let copyWindowSpaces = symbol("CGSCopySpacesForWindows", as: CopyWindowSpaces.self)
    static let currentSpace = symbol("CGSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
    static let spaceType = symbol("CGSSpaceGetType", as: SpaceType.self)
    static let setCurrentSpace = symbol("CGSManagedDisplaySetCurrentSpace", as: SetCurrentSpace.self)
    static let copyDisplay = symbol("CGSCopyManagedDisplayForSpace", as: CopyDisplay.self)
    static let cornerRadius = symbol("SLSGetDisplayCornerRadius", as: CornerRadius.self)
}

struct SpaceRef: Equatable {
    let id: UInt64
    /// 0 is a desktop, 4 is a fullscreen app. Other types (Dock, etc.) are excluded.
    let type: Int
    var isFullscreen: Bool { type == 4 }
}

/// The ordered Spaces of one display, preserving fullscreen apps in their actual positions.
struct SpaceLayout {
    let displayUUID: String
    let spaceIDs: [UInt64]
    var currentIndex: Int
    let desktopIDs: [UInt64]
    let screen: NSScreen

    var displayID: CGDirectDisplayID { screen.displayID }
}

/// Space identifiers, display association and switching, adapted from Interspace.
enum Spaces {
    /// Missing private functions disable the optional engine instead of breaking app launch.
    static var isAvailable: Bool {
        SkyLight.mainConnection != nil && SkyLight.copyManagedDisplays != nil
    }

    private static var connection: Int32? { SkyLight.mainConnection?() }

    /// Empty means unknown, including when a window has not been placed on screen yet.
    static func spaces(ofWindow windowNumber: Int) -> [UInt64] {
        guard windowNumber > 0, let connection, let copy = SkyLight.copyWindowSpaces else { return [] }
        let windows = [NSNumber(value: windowNumber)] as CFArray
        return (copy(connection, 7, windows)?.takeRetainedValue() as? [NSNumber])?.map { $0.uint64Value } ?? []
    }

    static let queryQueue = DispatchQueue(label: "com.lenotch.app.spaces.layout", qos: .userInteractive)

    /// Background callers pass the UUID captured on main, leaving AppKit access on main.
    static func layout(for screen: NSScreen, displayUUID: String? = nil) -> SpaceLayout? {
        guard let connection, connection != 0, let copy = SkyLight.copyManagedDisplays,
              let managed = copy(connection, nil)?.takeRetainedValue() as? [[String: Any]],
              !managed.isEmpty else { return nil }
        let uuid = displayUUID ?? self.displayUUID(screen)
        let entry = managed.first { ($0["Display Identifier"] as? String) == uuid } ?? managed[0]
        guard let entries = entry["Spaces"] as? [[String: Any]] else { return nil }
        let ids = entries.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard !ids.isEmpty,
              let current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value,
              let index = ids.firstIndex(of: current) else { return nil }
        let desktops = entries.compactMap { entry -> UInt64? in
            guard (entry["type"] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry["id64"] as? NSNumber)?.uint64Value
        }
        return SpaceLayout(displayUUID: entry["Display Identifier"] as? String ?? uuid,
                           spaceIDs: ids, currentIndex: index, desktopIDs: desktops, screen: screen)
    }

    static func displayUUID(_ screen: NSScreen) -> String {
        displayUUID(for: screen.displayID)
    }

    static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let value = CFUUIDCreateString(nil, uuid) else { return "Main" }
        return value as String
    }

    /// With separate Spaces off, the primary display's list is shared by every display.
    static func list(on screen: NSScreen) -> (display: String, spaces: [SpaceRef]) {
        let uuid = displayUUID(screen)
        guard let connection, let copy = SkyLight.copyManagedDisplays,
              let managed = copy(connection, nil)?.takeRetainedValue() as? [[String: Any]]
        else { return (uuid, []) }
        let info = managed.first { ($0["Display Identifier"] as? String) == uuid } ?? managed.first
        let identifier = info?["Display Identifier"] as? String ?? uuid
        let entries = info?["Spaces"] as? [[String: Any]] ?? []
        let refs = entries.compactMap { entry -> SpaceRef? in
            guard let id = (entry["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let type = (entry["type"] as? NSNumber)?.intValue,
                  type == 0 || type == 4 else { return nil }
            return SpaceRef(id: id, type: type)
        }
        return (identifier, refs)
    }

    static func current(on display: String) -> UInt64 {
        guard let connection, let current = SkyLight.currentSpace else { return 0 }
        return current(connection, display as CFString)
    }

    static func type(of space: UInt64) -> Int {
        guard let connection, let type = SkyLight.spaceType else { return -1 }
        return Int(type(connection, space))
    }

    static func managedDisplay(of space: UInt64) -> String? {
        guard let connection else { return nil }
        return SkyLight.copyDisplay?(connection, space)?.takeRetainedValue() as String?
    }

    static func switchTo(_ space: UInt64, on display: String) {
        guard isAvailable, let connection, type(of: space) == 0 || type(of: space) == 4 else { return }
        SkyLight.setCurrentSpace?(connection, display as CFString, space)
        if let front = NSWorkspace.shared.frontmostApplication {
            NSRunningApplication(processIdentifier: front.processIdentifier)?.activate(options: [])
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    var displayCornerRadius: CGFloat {
        let radius = SkyLight.cornerRadius?(displayID) ?? 0
        return radius > 0 ? radius : Config.fallbackCornerRadius
    }

    static var underMouse: NSScreen {
        let point = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(point) }) ?? main ?? screens[0]
    }

    static var underCursor: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main ?? screens.first
    }
}
