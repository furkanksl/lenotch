import AppKit
import Observation
import SwiftUI

/// Coordinates are measured from the top edge of the screen, matching the notch's geometry.
struct LauncherFanLayout: Equatable {
    static let pageSize = 5
    static let height: CGFloat = 350
    static let diameter: CGFloat = 72
    let width: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(width: CGFloat = 680, notchWidth: CGFloat = 185, notchHeight: CGFloat = 32) {
        self.width = max(300, width)
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    func spread(index: Int, count: Int) -> CGFloat {
        count <= 1 ? 0 : CGFloat(index) / CGFloat(count - 1) * 2 - 1
    }

    func center(index: Int, count: Int) -> CGPoint {
        let t = spread(index: index, count: count)
        let extent = min(width / 2 - 52, max(210, notchWidth / 2 + 125))
        return CGPoint(x: width / 2 + t * extent, y: notchHeight + 36 + 120 * (1 - t * t))
    }

    func origin(index: Int, count: Int) -> CGPoint {
        let target = center(index: index, count: count)
        let limit = max(0, notchWidth / 2 - 14)
        return CGPoint(x: width / 2 + min(max((target.x - width / 2) * 0.3, -limit), limit), y: notchHeight - 8)
    }

    var controls: CGRect { CGRect(x: width / 2 - 116, y: notchHeight + 250, width: 232, height: 32) }
    var empty: CGRect { CGRect(x: width / 2 - 145, y: notchHeight + 60, width: 290, height: 130) }

    func contains(_ point: CGPoint, count: Int) -> Bool {
        if count == 0 && empty.contains(point) { return true }
        if controls.insetBy(dx: -4, dy: -4).contains(point) { return true }
        return (0..<count).contains {
            let c = center(index: $0, count: count)
            // Include the icon's caption, but leave the large gaps in the fan click-through.
            return CGRect(x: c.x - 46, y: c.y - 44, width: 92, height: 112).contains(point)
        }
    }
}

@MainActor @Observable final class LauncherFanState {
    let model: LauncherModel
    var layout: LauncherFanLayout
    var presented = false
    var showsControls = true
    private(set) var animating = false
    private(set) var motion: LauncherDropMotion?
    private(set) var page = 0
    var highlighted: UUID?

    init(model: LauncherModel, layout: LauncherFanLayout = LauncherFanLayout()) {
        self.model = model
        self.layout = layout
    }

    var pages: Int { max(1, (model.items.count + LauncherFanLayout.pageSize - 1) / LauncherFanLayout.pageSize) }
    var items: [LauncherItem] {
        let start = min(page, pages - 1) * LauncherFanLayout.pageSize
        return Array(model.items.dropFirst(start).prefix(LauncherFanLayout.pageSize))
    }

    func reset() { page = 0; highlighted = nil }
    func changePage(_ delta: Int) {
        page = min(max(page + delta, 0), pages - 1)
        highlighted = nil
    }
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == highlighted }
        let index = current.map { ($0 + delta + items.count) % items.count } ?? (delta < 0 ? items.count - 1 : 0)
        highlighted = items[index].id
    }
    var selection: LauncherItem? { items.first { $0.id == highlighted } }

    func setPresented(_ presented: Bool, at time: Double = Date.timeIntervalSinceReferenceDate) {
        var motion = motion ?? LauncherDropMotion()
        motion.transition(opening: presented, count: items.count, at: time)
        self.motion = motion
        self.presented = presented
        animating = true
    }

    func finishTransition() { animating = false }

    func pose(index: Int, at time: Double, reduceMotion: Bool = false) -> LauncherDropPose {
        let progress = reduceMotion ? 1.0 : !animating ? (presented ? 1.0 : 0.0)
            : motion?.progress(index: index, count: items.count, at: time, settled: false) ?? 0
        return LauncherDropPose(layout: layout, index: index, count: items.count, progress: progress)
    }
}

/// A transparent fan, not another notch card. The owning panel supplies drop/return lifecycle state.
struct LauncherView: View {
    @Bindable var state: LauncherFanState
    let reduceMotion: Bool
    let onClose: () -> Void
    let onConfigure: () -> Void
    let onLaunch: (LauncherItem) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !state.animating || reduceMotion)) { context in
            animationFrame(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    func animationFrame(at time: Double) -> some View {
        ZStack(alignment: .topLeading) {
            LauncherLiquidLayer(layout: state.layout,
                poses: state.items.indices.map { state.pose(index: $0, at: time, reduceMotion: reduceMotion) },
                fluid: state.animating && !reduceMotion)
                .allowsHitTesting(false).accessibilityHidden(true)
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                let pose = state.pose(index: index, at: time, reduceMotion: reduceMotion)
                LauncherFanTarget(item: item, model: state.model, highlighted: state.highlighted == item.id) {
                    onLaunch(item)
                }
                .onHover { over in
                    if over { state.highlighted = item.id }
                    else if state.highlighted == item.id { state.highlighted = nil }
                }
                .scaleEffect(reduceMotion ? 1 : pose.scale)
                .opacity(reduceMotion ? (state.presented ? 1 : 0) : pose.reveal)
                // The 108 pt target includes a caption; the circle's center, not its container, follows the drop.
                .position(x: pose.center.x, y: pose.center.y + 18 * (reduceMotion ? 1 : pose.scale))
                .allowsHitTesting(state.presented && pose.reveal > 0.95)
                .animation(reduceMotion ? .easeOut(duration: 0.12) : nil, value: state.presented)
                .accessibilitySortPriority(Double(state.items.count - index))
            }

            if state.items.isEmpty {
                VStack(spacing: 10) {
                    Text("Your Launcher").font(.system(size: 16, weight: .semibold))
                    Text("Add apps, folders and websites.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    Button("Configure Launcher", action: onConfigure).buttonStyle(.bordered)
                }
                .foregroundStyle(.white).frame(width: state.layout.empty.width, height: state.layout.empty.height)
                .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .position(x: state.layout.empty.midX, y: state.layout.empty.midY)
                .opacity(state.presented ? 1 : 0)
            }

            if state.showsControls {
                HStack(spacing: 12) {
                    if state.pages > 1 {
                        control("chevron.left", label: "Previous launcher page", disabled: state.page == 0 || state.animating) { state.changePage(-1) }
                        Text("\(min(state.page + 1, state.pages)) / \(state.pages)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                        control("chevron.right", label: "Next launcher page", disabled: state.page >= state.pages - 1 || state.animating) { state.changePage(1) }
                        Divider().frame(height: 12).overlay(.white.opacity(0.15))
                    }
                    control("slider.horizontal.3", label: "Configure Launcher", action: onConfigure)
                    control("xmark", label: "Close Launcher", action: onClose)
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(.black.opacity(0.9), in: Capsule())
                .position(x: state.layout.controls.midX, y: state.layout.controls.midY)
                .opacity(state.presented ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: state.presented)
            }

            if let error = state.model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
                    .padding(10).background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
                    .frame(width: min(state.layout.width - 40, 410))
                    .position(x: state.layout.width / 2, y: state.layout.notchHeight + 224)
                    .opacity(state.presented ? 1 : 0).accessibilityLabel(error)
            }
        }
        .frame(width: state.layout.width, height: LauncherFanLayout.height)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ symbol: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(disabled ? 0.25 : 0.8)).frame(width: 20, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).accessibilityLabel(label).help(label)
    }
}

/// A thresholded blur merges the notch, leading drop and shrinking trailing drops into one
/// silhouette. Once detached, the sharp icon badges replace the fluid circles without a crossfade seam.
struct LauncherLiquidLayer: View {
    let layout: LauncherFanLayout
    let poses: [LauncherDropPose]
    let fluid: Bool

    var body: some View {
        Canvas { context, _ in
            let notch = Path(roundedRect: CGRect(x: layout.width / 2 - layout.notchWidth / 2, y: -32,
                                                width: layout.notchWidth, height: layout.notchHeight + 32),
                             cornerRadius: 11)
            context.fill(notch, with: .color(.black))
            guard fluid else { return }
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 9))
            context.drawLayer { layer in
                layer.fill(notch, with: .color(.white))
                for (index, pose) in poses.enumerated() where pose.isFluid {
                    func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    }
                    layer.fill(circle(pose.center, pose.radius), with: .color(.white))
                    for tail in pose.trailingDrops(layout: layout, index: index, count: poses.count) {
                        layer.fill(circle(tail.center, tail.radius), with: .color(.white))
                    }
                }
            }
        }
        .frame(width: layout.width, height: LauncherFanLayout.height)
    }
}

private struct LauncherFanTarget: View {
    let item: LauncherItem
    let model: LauncherModel
    let highlighted: Bool
    let action: () -> Void
    @State private var icon: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(.black)
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                        .padding(4)
                    Circle().strokeBorder(.white.opacity(highlighted ? 0.7 : 0.27), lineWidth: highlighted ? 2 : 1).padding(5)
                    if model.launchingID == item.id {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        if let icon {
                            Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
                        } else {
                            Image(systemName: item.kind.symbol).font(.system(size: 32)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: LauncherFanLayout.diameter, height: LauncherFanLayout.diameter)
                .shadow(color: .black.opacity(0.32), radius: 7, y: 4)
                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .foregroundStyle(.white).background(.black.opacity(0.8), in: Capsule())
                    .frame(maxWidth: 100)
            }
            .frame(width: 100, height: 108, alignment: .top)
            .scaleEffect(highlighted ? 1.06 : 1, anchor: .top)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: highlighted)
        }
        .buttonStyle(.plain).disabled(model.isLaunching)
        .onAppear { icon = model.icon(for: item) }
        .accessibilityLabel("Open \(item.title)").accessibilityHint(item.kind.label)
        .help(item.title)
    }
}
