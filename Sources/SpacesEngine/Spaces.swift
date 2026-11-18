import AppKit

/// Optional SkyLight functions. Keep the framework open for the lifetime of its function pointers.
private enum SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyManagedDisplays = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?

    static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    static let copyManagedDisplays = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplays.self)
}

/// The ordered Spaces of one display, preserving fullscreen apps in their actual positions.
struct SpaceLayout {
    let displayUUID: String
    let spaceIDs: [UInt64]
    let currentIndex: Int
    let displayID: CGDirectDisplayID
}

/// Space identifiers and display association, adapted from Interspace.
enum Spaces {
    /// Missing private functions disable the optional engine instead of breaking app launch.
    static var isAvailable: Bool {
        SkyLight.mainConnection != nil && SkyLight.copyManagedDisplays != nil
    }

    private static var connection: Int32? { SkyLight.mainConnection?() }

    static let queryQueue = DispatchQueue(label: "com.lenotch.app.spaces.layout", qos: .userInteractive)

    static func layout(for displayID: CGDirectDisplayID) -> SpaceLayout? {
        guard let connection, connection != 0, let copy = SkyLight.copyManagedDisplays,
              let managed = copy(connection, nil)?.takeRetainedValue() as? [[String: Any]],
              !managed.isEmpty else { return nil }
        let uuid = displayUUID(for: displayID)
        guard let entry = managed.first(where: { ($0["Display Identifier"] as? String) == uuid })
                ?? (managed.count == 1 ? managed.first : nil) else { return nil }
        guard let entries = entry["Spaces"] as? [[String: Any]] else { return nil }
        let ids = entries.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard !ids.isEmpty,
              let current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value,
              let index = ids.firstIndex(of: current) else { return nil }
        return SpaceLayout(displayUUID: entry["Display Identifier"] as? String ?? uuid,
                           spaceIDs: ids, currentIndex: index, displayID: displayID)
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let value = CFUUIDCreateString(nil, uuid) else { return "Main" }
        return value as String
    }

}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static var underCursor: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main ?? screens.first
    }
}
