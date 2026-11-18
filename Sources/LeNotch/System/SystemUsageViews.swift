import AppKit
import SwiftUI

/// Shares the tray's black surface, tabular numerals, and round back control.
struct SystemUsagePage: View {
    let model: SystemUsageModel
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Back")
                Text("System").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
            }
            .frame(height: 28)
            VStack(spacing: 6) {
                SystemMetricRow(title: "CPU", symbol: "cpu", fraction: model.snapshot.cpuFraction,
                                detail: cpuDetail, tint: IslandColor.cyan, thresholds: .processor)
                    .help("Total processor load across all CPU cores. Updates every two seconds while this page is open.")
                SystemMetricRow(title: "Memory", symbol: "memorychip", fraction: model.snapshot.memory?.fraction,
                                detail: capacityText(model.snapshot.memory, memory: true),
                                tint: IslandColor.indigo, thresholds: .memory)
                    .help("Memory used by apps, wired memory, and compressed memory. Reclaimable cache is excluded.")
                SystemMetricRow(title: "Storage", symbol: "internaldrive", fraction: model.snapshot.storage?.fraction,
                                detail: capacityText(model.snapshot.storage, memory: false),
                                tint: IslandColor.green, thresholds: .storage)
                    .help("Startup disk usage. Available capacity may include space macOS can reclaim.")
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }

    private var cpuDetail: String {
        switch model.snapshot.cpuStatus {
        case .collecting: "Measuring…"
        case .available: "All cores"
        case .unavailable: "Unavailable"
        }
    }

    private func capacityText(_ usage: SystemCapacityUsage?, memory: Bool) -> String {
        guard let usage else {
            return model.snapshot.updatedAt == nil && model.snapshot.cpuStatus == .collecting ? "Loading…" : "Unavailable"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = memory ? .memory : .file
        formatter.allowedUnits = [.useGB, .useTB]
        return "\(formatter.string(fromByteCount: Int64(clamping: usage.usedBytes))) / \(formatter.string(fromByteCount: Int64(clamping: usage.totalBytes)))"
    }
}

/// Where a metric turns from normal to worth noticing. A busy CPU is routine; a nearly full disk is not,
/// so each gets its own limits instead of one shared warning color.
struct SystemUsageThresholds: Equatable {
    let warning: Double
    let critical: Double

    static let processor = SystemUsageThresholds(warning: 0.75, critical: 0.9)
    static let memory = SystemUsageThresholds(warning: 0.8, critical: 0.92)
    static let storage = SystemUsageThresholds(warning: 0.85, critical: 0.95)

    enum Level: Equatable { case normal, warning, critical }

    func level(for fraction: Double?) -> Level {
        guard let fraction else { return .normal }
        if fraction >= critical { return .critical }
        if fraction >= warning { return .warning }
        return .normal
    }
}

private struct SystemMetricRow: View {
    let title: String
    let symbol: String
    let fraction: Double?
    let detail: String
    let tint: Color
    let thresholds: SystemUsageThresholds
    @Environment(\.islandMotion) private var motion

    private var level: SystemUsageThresholds.Level { thresholds.level(for: fraction) }
    private var accent: Color {
        switch level {
        case .normal: tint
        case .warning: IslandColor.orange
        case .critical: IslandColor.red
        }
    }
    private var percent: Int? { fraction.map { Int((min(max($0, 0), 1) * 100).rounded()) } }
    private var percentage: String { percent.map { "\($0)%" } ?? "—" }
    private var colorAnimation: Animation? { motion.reduce || motion.stills ? nil : .easeOut(duration: 0.3) }

    /// The percentage is the tallest text in the row. Its line box holds ascender space above the capitals, so
    /// centering the boxes sits the tile visibly high. The tile centers on the visible content instead: from
    /// the top of the capitals to the bottom of the bar.
    private static let capHeight: CGFloat = NSFont.systemFont(ofSize: 15, weight: .semibold).capHeight

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(IslandColor.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Text(percentage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(level == .normal ? Color.white : accent)
                        .contentTransition(.numericText(value: Double(percent ?? 0)))
                }
                .monospacedDigit()
                SystemUsageBar(fraction: fraction, tint: accent)
            }
            .alignmentGuide(VerticalAlignment.center) { d in
                (d[.firstTextBaseline] - Self.capHeight + d[.bottom]) / 2
            }
        }
        .frame(maxHeight: .infinity)
        .animation(colorAnimation, value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(fraction == nil ? detail : "\(percentage), \(detail)")
    }
}

/// A rounded track with a gradient fill, a soft top highlight, and quarter marks that read as a scale.
/// The fill glides between samples instead of jumping, and an empty reading shows the bare track.
struct SystemUsageBar: View {
    let fraction: Double?
    let tint: Color
    @Environment(\.islandMotion) private var motion

    static let height: CGFloat = 8

    private var value: Double { min(max(fraction ?? 0, 0), 1) }
    private var glide: Animation? { motion.reduce || motion.stills ? nil : .smooth(duration: 0.6) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Any real reading shows at least a full cap, so 1% stays visible as a rounded dot, not a sliver.
            let fill = fraction == nil || value == 0 ? 0 : max(value * width, Self.height)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(height: Self.height / 2)
                            .padding(.horizontal, 1.5)
                            .padding(.top, 0.5)
                    }
                    .frame(width: fill)
                    .shadow(color: tint.opacity(0.4), radius: 4)
                    .opacity(fill > 0 ? 1 : 0)
                ForEach([0.25, 0.5, 0.75], id: \.self) { mark in
                    Rectangle().fill(.black.opacity(0.28))
                        .frame(width: 1, height: Self.height)
                        .offset(x: width * mark - 0.5)
                }
            }
            .clipShape(Capsule())
            .animation(glide, value: value)
            .animation(motion.reduce || motion.stills ? nil : .easeOut(duration: 0.3), value: tint)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
