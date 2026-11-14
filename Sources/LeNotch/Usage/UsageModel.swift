import Foundation
import Observation

/// Consent is persisted; usage snapshots and credentials are not. Construction/start while disabled does no I/O.
@MainActor @Observable final class UsageModel {
    static let shared = UsageModel()
    static let pollingInterval: TimeInterval = 5 * 60
    private(set) var states: [UsageProvider: UsageProviderState] = [:]
    private(set) var enabledProviders: Set<UsageProvider>
    var selectedProvider: UsageProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: "usage.selectedProvider") }
    }
    private(set) var isRunning = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sources: [UsageProvider: any UsageSource]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var requests: [UsageProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UsageProvider: UUID] = [:]

    init(defaults: UserDefaults = .standard,
         sources: [UsageProvider: any UsageSource]? = nil,
         pollingInterval: TimeInterval = UsageModel.pollingInterval,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.sources = sources ?? [.claude: ClaudeUsageSource(), .codex: CodexUsageSource()]
        self.now = now
        interval = max(60, pollingInterval)
        enabledProviders = Set(UsageProvider.allCases.filter { defaults.bool(forKey: Self.enabledKey($0)) })
        selectedProvider = UsageProvider(rawValue: defaults.string(forKey: "usage.selectedProvider") ?? "") ?? .claude
    }

    deinit {
        pollingTask?.cancel()
        for request in requests.values { request.cancel() }
    }

    func state(for provider: UsageProvider) -> UsageProviderState { states[provider] ?? UsageProviderState() }
    func isEnabled(_ provider: UsageProvider) -> Bool { enabledProviders.contains(provider) }
    var enabled: Bool { !enabledProviders.isEmpty }

    /// Call for the application lifetime, not only while the card is open, to keep usage proactive.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh(reason: .background)
        let interval = interval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard let self, self.isRunning else { return }
                self.refresh(reason: .background)
            }
        }
    }

    func stop() {
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        for provider in UsageProvider.allCases { cancel(provider) }
    }

    /// UI must display the disclosure in UsageSettingsSection before granting consent.
    func setEnabled(_ enabled: Bool, for provider: UsageProvider) {
        guard enabled != isEnabled(provider) else { return }
        defaults.set(enabled, forKey: Self.enabledKey(provider))
        if enabled {
            enabledProviders.insert(provider)
            if isRunning { refresh(provider: provider, reason: .userInitiated) }
        } else {
            enabledProviders.remove(provider)
            cancel(provider)
            states[provider] = UsageProviderState()
        }
    }

    /// Manual refresh. No requests are sent for disabled providers, even when explicitly refreshed.
    func refresh() { refresh(reason: .userInitiated) }

    func refresh(provider: UsageProvider) { refresh(provider: provider, reason: .userInitiated) }

    private func refresh(reason: UsageRefreshReason) {
        for provider in UsageProvider.allCases { refresh(provider: provider, reason: reason) }
    }

    private func refresh(provider: UsageProvider, reason: UsageRefreshReason) {
        guard isRunning, isEnabled(provider), requests[provider] == nil else { return }
        var state = state(for: provider)
        if let retryAfter = state.retryAfter, retryAfter > now() { return }
        // Do not repeatedly touch Keychain or rejected credentials in the background.
        if reason == .background, let error = state.error,
           [.signInRequired, .credentialExpired, .keychainDenied, .invalidResponse, .sourceUnavailable].contains(error) { return }
        guard let source = sources[provider] else {
            state.error = .sourceUnavailable
            states[provider] = state
            return
        }
        let generation = UUID()
        generations[provider] = generation
        state.isRefreshing = true
        state.lastAttemptAt = now()
        states[provider] = state
        requests[provider] = Task { [weak self] in
            let result: Result<UsageSnapshot, UsageFailure>
            do {
                let snapshot = try await source.fetch(reason: reason)
                try Task.checkCancellation()
                guard snapshot.provider == provider, !snapshot.limits.isEmpty else { throw UsageFailure.invalidResponse }
                result = .success(snapshot)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                result = .failure(.network)
            }
            catch let error as URLError where error.code == .cancelled {
                guard !Task.isCancelled else { return }
                result = .failure(.network)
            }
            catch let error as UsageFailure { result = .failure(error) }
            catch { result = .failure(.sourceUnavailable) }
            guard !Task.isCancelled, let self, self.isRunning, self.isEnabled(provider),
                  self.generations[provider] == generation else { return }
            self.requests[provider] = nil
            var state = self.state(for: provider)
            state.isRefreshing = false
            switch result {
            case .success(let snapshot):
                state.snapshot = snapshot
                state.lastRefreshedAt = self.now()
                state.error = nil
                state.retryAfter = nil
            case .failure(let failure):
                state.error = failure
                if case .rateLimited(let delay) = failure {
                    state.retryAfter = self.now().addingTimeInterval(min(86_400, max(60, delay)))
                }
            }
            self.states[provider] = state
        }
    }

    private func cancel(_ provider: UsageProvider) {
        generations[provider] = UUID()
        requests.removeValue(forKey: provider)?.cancel()
        if var state = states[provider] { state.isRefreshing = false; states[provider] = state }
    }

    private static func enabledKey(_ provider: UsageProvider) -> String { "usage.\(provider.rawValue).enabled" }
}
