import Foundation
import CoreGraphics

/// A trackpad report. Finger coordinates are normalized left-to-right / bottom-to-top.
struct TouchFrame {
    let device: UInt
    let timestamp: Double
    let points: [CGPoint]
}

/// Raw contacts from the optional MultitouchSupport framework. Lifecycle and onFrame run on main.
/// There is deliberately no shared monitor: LeNotch owns and stops an instance with the feature.
final class MultitouchMonitor {
    var onFrame: ((TouchFrame) -> Void)?

    private typealias DeviceRef = UnsafeMutableRawPointer
    fileprivate typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (DeviceRef, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (DeviceRef, Int32) -> Int32
    private typealias StopFn = @convention(c) (DeviceRef) -> Int32

    private var createList: CreateListFn?
    private var register: RegisterFn?
    private var unregister: RegisterFn?
    private var startDevice: StartFn?
    private var stopDevice: StopFn?
    private var framework: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [DeviceRef] = []
    private(set) var deviceCount = 0

    // Multitouch callbacks are not on main. Every cross-thread state access uses this lock.
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var running = false
    private var lastCount: [UInt: Int] = [:]

    init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return }
        framework = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        createList = symbol("MTDeviceCreateList", CreateListFn.self)
        register = symbol("MTRegisterContactFrameCallback", RegisterFn.self)
        unregister = symbol("MTUnregisterContactFrameCallback", RegisterFn.self)
        startDevice = symbol("MTDeviceStart", StartFn.self)
        stopDevice = symbol("MTDeviceStop", StopFn.self)
    }

    deinit {
        stop()
        // Keep the framework mapped: its callback code can still be unwinding after MTDeviceStop.
    }

    var isAvailable: Bool {
        createList != nil && register != nil && unregister != nil && startDevice != nil && stopDevice != nil
    }

    @discardableResult
    func start() -> Bool {
        stop()
        guard isAvailable, let createList, let register, let startDevice,
              let list = createList()?.takeRetainedValue() else { return false }
        deviceList = list
        lock.lock()
        running = true
        let epoch = generation
        lock.unlock()
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            guard MultitouchRecipients.claim(device, monitor: self, generation: epoch) else { continue }
            devices.append(device)
            register(device, contactCallback)
            _ = startDevice(device, 0)
        }
        deviceCount = devices.count
        if devices.isEmpty { stop() }
        return !devices.isEmpty
    }

    /// Invalidates queued frames before unregistering callbacks and releasing the retained device list.
    func stop() {
        lock.lock()
        running = false
        generation &+= 1
        lastCount.removeAll()
        lock.unlock()
        for device in devices {
            MultitouchRecipients.remove(device, monitor: self)
            unregister?(device, contactCallback)
            _ = stopDevice?(device)
        }
        devices.removeAll()
        deviceList = nil
        deviceCount = 0
    }

    fileprivate func receive(_ frame: TouchFrame, generation epoch: UInt64) {
        lock.lock()
        guard running, generation == epoch else { lock.unlock(); return }
        let previous = lastCount[frame.device] ?? 0
        lastCount[frame.device] = frame.points.count
        lock.unlock()
        // Ordinary pointer movement, scrolling and clicking never enter the main queue.
        guard frame.points.count >= 3 || previous >= 3 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.running && self.generation == epoch
            self.lock.unlock()
            guard current else { return }
            self.onFrame?(frame)
        }
    }
}

/// The C callback has no user-data argument; route devices to weak, explicitly started owners.
private enum MultitouchRecipients {
    private final class Recipient {
        weak var monitor: MultitouchMonitor?
        let generation: UInt64
        init(_ monitor: MultitouchMonitor, generation: UInt64) {
            self.monitor = monitor
            self.generation = generation
        }
    }
    private static let lock = NSLock()
    private static var recipients: [UInt: Recipient] = [:]

    static func claim(_ device: UnsafeMutableRawPointer, monitor: MultitouchMonitor, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: device)
        guard recipients[key]?.monitor == nil else { return false }
        recipients[key] = Recipient(monitor, generation: generation)
        return true
    }

    static func remove(_ device: UnsafeMutableRawPointer, monitor: MultitouchMonitor) {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: device)
        if recipients[key]?.monitor === monitor { recipients[key] = nil }
    }

    static func recipient(for device: UInt) -> (MultitouchMonitor, UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let recipient = recipients[device], let monitor = recipient.monitor else { return nil }
        return (monitor, recipient.generation)
    }
}

// MTTouch ABI: 96-byte contacts, int32 state at byte 20, normalized float x/y at 32/36.
private let contactCallback: MultitouchMonitor.ContactCallback = { device, touches, count, timestamp, _ in
    guard let device, timestamp.isFinite, count >= 0, count <= 64,
          let (monitor, generation) = MultitouchRecipients.recipient(for: UInt(bitPattern: device)) else { return 0 }
    var points: [CGPoint] = []
    if let touches, count > 0 {
        points.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let touch = touches.advanced(by: index * 96)
            let state = touch.load(fromByteOffset: 20, as: Int32.self)
            guard state == 3 || state == 4 else { continue }
            let x = touch.load(fromByteOffset: 32, as: Float.self)
            let y = touch.load(fromByteOffset: 36, as: Float.self)
            guard x.isFinite, y.isFinite else { continue }
            points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }
    }
    monitor.receive(TouchFrame(device: UInt(bitPattern: device), timestamp: timestamp, points: points), generation: generation)
    return 0
}
