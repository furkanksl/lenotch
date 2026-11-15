import IslandCore
import SwiftUI

extension UsageProvider {
    var agentProvider: AgentProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// A standalone native notch card. Director integration supplies navigation; it never enables a source itself.
struct UsageView: View {
    static let cardWidth: CGFloat = 480
    static let cardHeight: CGFloat = 266

    @Bindable var model: UsageModel
    var onClose: () -> Void
    var onOpenSettings: () -> Void

    init(model: UsageModel = .shared, onClose: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 10) {
                header
                providerPicker
                let state = model.state(for: model.selectedProvider)
                if model.isEnabled(model.selectedProvider), let snapshot = state.snapshot {
                    limits(snapshot, state: state, now: context.date)
                } else {
                    unavailable(state)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .top)
            .foregroundStyle(.white)
            .background(.black)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.pie.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            Text("Usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            let state = model.state(for: model.selectedProvider)
            if state.isRefreshing {
                ProgressView().controlSize(.mini).tint(.white).accessibilityLabel("Refreshing usage")
            }
            iconButton("arrow.clockwise", label: "Refresh usage") { model.refresh(provider: model.selectedProvider) }
                .disabled(!model.isEnabled(model.selectedProvider) || state.isRefreshing || (state.retryAfter.map { $0 > Date() } ?? false))
            iconButton("gearshape", label: "Usage settings", action: onOpenSettings)
            iconButton("xmark", label: "Close usage", action: onClose)
        }
        .frame(height: 20)
    }

    private var providerPicker: some View {
        HStack(spacing: 4) {
            ForEach(UsageProvider.allCases) { provider in
                Button {
                    model.selectedProvider = provider
                } label: {
                    HStack(spacing: 6) {
                        AgentMark(provider: provider.agentProvider, size: 14)
                            .accessibilityHidden(true)
                        Text(provider.title).font(.system(size: 11, weight: .semibold))
                        if !model.isEnabled(provider) {
                            Text("Off").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(model.selectedProvider == provider ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.selectedProvider == provider ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
    }

    private func limits(_ snapshot: UsageSnapshot, state: UsageProviderState, now: Date) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 14) {
                ForEach(0..<2) { index in
                    if snapshot.limits.indices.contains(index) {
                        UsageLimitRing(limit: snapshot.limits[index], now: now, tint: color(snapshot.provider))
                    } else {
                        missingLimit(provider: snapshot.provider)
                    }
                    if index == 0 {
                        Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 88)
                    }
                }
            }
            .frame(height: 119)
            VStack(spacing: 3) {
                if let error = state.error {
                    Text(error.message(for: snapshot.provider))
                        .font(.system(size: 10)).foregroundStyle(IslandColor.orange)
                        .lineLimit(1).help(error.message(for: snapshot.provider))
                } else if snapshot.isStale(at: now) {
                    Text("Last known usage · refresh for the current allowance")
                        .font(.system(size: 10)).foregroundStyle(IslandColor.orange)
                }
                HStack(spacing: 4) {
                    Text(snapshot.sourceDescription)
                    if let plan = snapshot.plan { Text("· \(plan)") }
                    Text("·")
                    Text(snapshot.observedAt, style: .relative)
                    Text("ago")
                    Spacer(minLength: 0)
                    if state.isStale(at: now) { Text("STALE").font(.system(size: 8, weight: .semibold)) }
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .help(state.lastRefreshedAt.map { "Last read: \($0.formatted()). Percentages are provider-reported usage, not token estimates." }
                    ?? "Percentages are provider-reported usage, not token estimates.")
            }
        }
    }

    private func unavailable(_ state: UsageProviderState) -> some View {
        let provider = model.selectedProvider
        let enabled = model.isEnabled(provider)
        return VStack(spacing: 9) {
            Image(systemName: enabled ? "chart.pie" : "lock.shield")
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(color(provider).opacity(0.8))
            Text(enabled ? (state.isRefreshing ? "Checking \(provider.title)…" : "Usage unavailable") : "Connect \(provider.title) usage")
                .font(.system(size: 13, weight: .semibold))
            Text(enabled ? (state.error?.message(for: provider) ?? "Waiting for a real usage snapshot.")
                : (provider == .claude ? "Optional access to Claude Code’s sign-in.\nEnable in Setup after reviewing how it works."
                    : "Read provider-reported limits from local Codex sessions.\nNo token estimates and no network requests."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).lineLimit(3)
                .frame(maxWidth: 370)
            Button("Open usage settings", action: onOpenSettings)
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func missingLimit(provider: UsageProvider) -> some View {
        VStack(spacing: 7) {
            Text("—").font(.system(size: 25, weight: .light)).foregroundStyle(.white.opacity(0.35))
            Text(provider == .claude ? "Weekly unavailable" : "No second window")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            Text("Not reported by provider").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
    }

    private func color(_ provider: UsageProvider) -> Color { provider == .claude ? IslandColor.orange : IslandColor.green }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct UsageLimitRing: View {
    let limit: UsageLimit
    let now: Date
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.09), lineWidth: 5)
                if !limit.resetHasPassed(at: now) {
                    Circle().trim(from: 0, to: CGFloat(limit.remainingPercent / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(limit.resetHasPassed(at: now) ? "—" : "\(Int(limit.remainingPercent.rounded()))%")
                        .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("remaining").font(.system(size: 8)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 73, height: 73)
            Text(limit.title).font(.system(size: 11, weight: .semibold))
            Text(limit.resetDescription(at: now)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.resetHasPassed(at: now)
            ? "\(limit.title), awaiting a new usage window"
            : "\(limit.title), \(Int(limit.remainingPercent.rounded())) percent remaining, \(limit.resetDescription(at: now))")
    }
}

/// Embed in Setup → Claude & Codex. Turning off a source cancels work and clears its in-memory snapshots.
struct UsageSettingsSection: View {
    @Bindable var model: UsageModel

    init(model: UsageModel = .shared) { self.model = model }

    var body: some View {
        SetupGroup("Usage limits") {
            providerRow(.claude)
            providerRow(.codex)
            SetupNote(icon: .lock, text: "Real limits, opt-in. Snapshots stay in memory, refreshed every five minutes while enabled. LeNotch never stores tokens, reads browser cookies, changes your sign-in, or estimates quotas from token counts.")
        }
    }

    private func providerRow(_ provider: UsageProvider) -> some View {
        SetupToggleRow(icon: provider == .claude ? .claude : .chatGPT,
                       title: provider == .claude ? "Claude subscription usage" : "Codex local usage",
                       detail: provider == .claude ? "Your plan’s limits, from Anthropic." : "Rate limits from recent Codex sessions on this Mac.",
                       isOn: Binding(get: { model.isEnabled(provider) }, set: { model.setEnabled($0, for: provider) })) {
            VStack(alignment: .leading, spacing: 10) {
                Text(provider == .claude
                    ? "By enabling, you allow LeNotch to read Claude Code’s existing sign-in from macOS Keychain and send it only to api.anthropic.com for usage. No conversations are sent. This private endpoint may change. Open Claude Code to renew an expired sign-in; LeNotch never refreshes tokens."
                    : "Reads provider-reported rate-limit events from a bounded set of recent local Codex session logs. No network access or credentials. Use a signed-in Codex session to update the snapshot. It may be old or from your previous account after switching accounts.")
                    .font(.system(size: 12)).foregroundStyle(SetupTheme.textSecondary).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isEnabled(provider) {
                    let state = model.state(for: provider)
                    HStack(spacing: 10) {
                        SetupStatusLine(kind: state.error != nil ? .failure : state.isRefreshing ? .progress : state.snapshot == nil ? .info : .success,
                                        text: state.error?.message(for: provider) ?? (state.snapshot == nil ? "Waiting for usage data" : "Connected"))
                        Spacer(minLength: 0)
                        Button("Refresh") { model.refresh(provider: provider) }
                            .buttonStyle(SetupButtonStyle(kind: .secondary))
                            .disabled(state.isRefreshing || (state.retryAfter.map { $0 > Date() } ?? false))
                    }
                }
            }
        }
        .accessibilityHint(provider == .claude ? "Allows reading the existing Claude Code Keychain sign-in and requesting subscription usage from Anthropic."
            : "Allows reading rate-limit snapshots in recent local Codex session files. No network requests.")
    }
}
