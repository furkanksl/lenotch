import Foundation
import Observation
import SpacesEngine

@MainActor
protocol DesktopTransitionsDriving: AnyObject {
    var onStatus: ((DesktopTransitionStatus) -> Void)? { get set }
    var onTransition: ((Bool) -> Void)? { get set }
    func start(_ options: DesktopTransitionOptions)
    func update(_ options: DesktopTransitionOptions)
    func setSuspended(_ suspended: Bool)
    func stop()
}

extension DesktopTransitionsEngine: DesktopTransitionsDriving {}

/// The feature is opt-in and inert by default, including construction of its private-API backend.
@MainActor @Observable
final class DesktopTransitionsModel {
    static let shared = DesktopTransitionsModel()
    static let enabledKey = "lenotch.spaces.enabled"
    private static let slideDurationKey = "lenotch.spaces.slideDuration"
    /// Window-list polling waits while the Dock changes Spaces (`userInfo["active"]`).
    static let transitionChanged = Notification.Name("lenotch.spaces.transitionChanged")
    private(set) var isTransitioning = false
    private(set) var enabled: Bool
    private(set) var options: DesktopTransitionOptions
    private(set) var status = DesktopTransitionStatus.off
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeDriver: () -> any DesktopTransitionsDriving
    @ObservationIgnored private var driver: (any DesktopTransitionsDriving)?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = UUID()

    init(defaults: UserDefaults = .standard,
         makeDriver: @escaping () -> any DesktopTransitionsDriving = { DesktopTransitionsProcess() }) {
        self.defaults = defaults
        self.makeDriver = makeDriver
        enabled = defaults.bool(forKey: Self.enabledKey)
        options = DesktopTransitionOptions(
            style: defaults.string(forKey: "lenotch.spaces.style").flatMap(DesktopTransitionStyle.init(rawValue:)) ?? .system,
            sensitivity: defaults.object(forKey: "lenotch.spaces.sensitivity") as? Double ?? 1,
            slideDuration: defaults.object(forKey: Self.slideDurationKey) as? Double ?? DesktopTransitionOptions.defaultSlideDuration)
    }

    func start() { started = true; reconcile() }
    func stop() { started = false; stopDriver() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        reconcile()
    }

    func configure(style: DesktopTransitionStyle? = nil, sensitivity: Double? = nil, slideDuration: Double? = nil) {
        let next = DesktopTransitionOptions(style: style ?? options.style,
                                            sensitivity: sensitivity ?? options.sensitivity,
                                            slideDuration: slideDuration ?? options.slideDuration)
        guard next != options else { return }
        options = next
        defaults.set(next.style.rawValue, forKey: "lenotch.spaces.style")
        defaults.set(next.sensitivity, forKey: "lenotch.spaces.sensitivity")
        defaults.set(next.slideDuration, forKey: Self.slideDurationKey)
        driver?.update(next)
    }

    /// Return control to macOS while locked, sharing/presenting, or switching users.
    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        driver?.setSuspended(suspended)
    }

    private func reconcile() {
        guard started, enabled else { stopDriver(); return }
        guard driver == nil else { return }
        let driver = makeDriver(), generation = UUID()
        self.generation = generation
        self.driver = driver
        driver.onStatus = { [weak self] status in
            guard let self, self.enabled, self.started, self.generation == generation else { return }
            self.status = status
        }
        driver.onTransition = { [weak self] active in
            guard let self, self.generation == generation else { return }
            self.setTransitioning(active)
        }
        driver.setSuspended(suspended)
        driver.start(options)
    }

    private func setTransitioning(_ active: Bool) {
        guard active != isTransitioning else { return }
        isTransitioning = active
        NotificationCenter.default.post(name: Self.transitionChanged, object: nil, userInfo: ["active": active])
    }

    private func stopDriver() {
        generation = UUID()
        setTransitioning(false)
        driver?.stop()
        driver?.onTransition = nil
        driver?.onStatus = nil
        driver = nil
        status = .off
    }
}
