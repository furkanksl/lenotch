import AppKit
import SwiftUI

/// A shallow fan under the camera, using the tray's rounded-square targets. The host
/// supplies the card's black shape; this view also renders independently for previews.
struct LauncherView: View {
    let model: LauncherModel
    let onClose: () -> Void
    let onConfigure: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandMotion) private var motion
    @Environment(\.presenting) private var presenting
    @State private var page = 0

    static let itemsPerPage = 7
    private var pageCount: Int { max(1, (model.items.count + Self.itemsPerPage - 1) / Self.itemsPerPage) }
    private var pageItems: [LauncherItem] {
        Array(model.items.dropFirst(min(page, pageCount - 1) * Self.itemsPerPage).prefix(Self.itemsPerPage))
    }

    init(model: LauncherModel, onClose: @escaping () -> Void, onConfigure: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        self.onConfigure = onConfigure
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Launcher").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if model.isLaunching {
                    ProgressView().controlSize(.mini).accessibilityLabel("Opening item")
                }
                headerButton("slider.horizontal.3", label: "Configure Launcher", action: onConfigure)
                headerButton("xmark", label: "Close Launcher", action: onClose)
            }
            .frame(height: 28)

            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(IslandColor.secondary)
                    Text("Add apps, folders, and links")
                        .font(.system(size: 13, weight: .medium))
                    Button("Configure Launcher…", action: onConfigure)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(IslandColor.green)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, item in
                        let spread = pageItems.count > 1 ? Double(index) / Double(pageItems.count - 1) * 2 - 1 : 0
                        target(item)
                            .position(x: proxy.size.width / Double(pageItems.count) * (Double(index) + 0.5),
                                      y: 43 + 19 * spread * spread)
                            .accessibilitySortPriority(Double(pageItems.count - index))
                    }
                }
                .frame(height: 109)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Launcher items, page \(page + 1) of \(pageCount)")

                if let error = model.errorMessage {
                    HStack(spacing: 8) {
                        Text(error).font(.system(size: 11)).foregroundStyle(IslandColor.orange)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.clearError() } label: {
                            Image(systemName: "xmark").font(.system(size: 9)).frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain).foregroundStyle(IslandColor.secondary)
                        .accessibilityLabel("Dismiss Launcher error")
                    }
                    .frame(minHeight: 28)
                } else {
                    HStack(spacing: 12) {
                        if pageCount > 1 {
                            Button { page = max(0, page - 1) } label: {
                                Image(systemName: "chevron.left").frame(width: 26, height: 26)
                            }
                            .disabled(page == 0).accessibilityLabel("Previous Launcher page")
                            Text("\(page + 1) / \(pageCount)").monospacedDigit()
                            Button { page = min(pageCount - 1, page + 1) } label: {
                                Image(systemName: "chevron.right").frame(width: 26, height: 26)
                            }
                            .disabled(page + 1 >= pageCount).accessibilityLabel("Next Launcher page")
                        } else {
                            Text("Choose an item to open it")
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(IslandColor.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 16)
        .foregroundStyle(.white).background(.black)
        .onChange(of: model.items.count) { _, _ in page = min(page, pageCount - 1) }
        .animation(reduceMotion || motion.reduce ? nil : .easeOut(duration: 0.15), value: page)
    }

    private func target(_ item: LauncherItem) -> some View {
        Button {
            Task { @MainActor in
                if await model.launch(item) { onClose() }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.10))
                    if let icon = model.icon(for: item) {
                        Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                            .frame(width: item.kind == .link ? 25 : 36, height: item.kind == .link ? 25 : 36)
                    } else {
                        Image(systemName: item.kind.symbol).font(.system(size: 25))
                    }
                }
                .frame(width: 48, height: 48)
                Text(presenting ? item.kind.label : item.title)
                    .font(.system(size: 10, weight: .medium)).lineLimit(2)
                    .multilineTextAlignment(.center).frame(width: 58, height: 26, alignment: .top)
            }
            .frame(width: 60, height: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherTargetStyle(reduceMotion: reduceMotion || motion.reduce))
        .disabled(model.isLaunching)
        .help(presenting ? "Open \(item.kind.label.lowercased())" : item.url.isFileURL ? item.url.path : item.url.absoluteString)
        .accessibilityLabel("Open \(presenting ? item.kind.label : item.title)")
        .accessibilityHint(item.kind.label)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(IslandColor.secondary).help(label).accessibilityLabel(label)
    }
}

private struct LauncherTargetStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
