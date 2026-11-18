import AppKit
import SwiftUI

// Setup speaks KLOI's settings language: a warm canvas with the sidebar on it, one large white card with a 48-point
// leading curve, soft #FAF9F7 rows, bold 15-point titles, Hugeicons outlines and a single orange accent (#fb9049).
// Every color resolves per appearance, mirroring KLOI's dark-mode mapping (black/x ink becomes white at fixed steps).

// MARK: - Colors

enum SetupTheme {
    static let accent = Color(nsColor: .setupHex(0xFB9049))
    static let accentHover = Color(nsColor: .setupHex(0xF57F34))
    static let danger = Color(nsColor: .setupHex(0xEF4444))

    /// The window behind the sidebar and around the card.
    static let canvas = dynamic(.setupHex(0xF2F1EF), .setupHex(0x111110))
    /// The large content card, and white controls on it.
    static let card = dynamic(.white, .setupHex(0x171716))
    /// A row on the card.
    static let row = dynamic(.setupHex(0xFAF9F7), .setupHex(0x171716))
    static let rowHover = dynamic(.setupHex(0xF2F1EF), .setupHex(0x1F1F1D))
    static let controlHover = dynamic(.setupHex(0xF9FAFB), .setupHex(0x1F1F1D))
    /// Hairline rings and dividers.
    static let ring = dynamic(.black.withAlphaComponent(0.04), .white.withAlphaComponent(0.08))
    static let ringStrong = dynamic(.black.withAlphaComponent(0.06), .white.withAlphaComponent(0.08))
    /// A tinted fill on the card (chips, tracks, inactive tiles).
    static let fill = dynamic(.black.withAlphaComponent(0.04), .white.withAlphaComponent(0.06))
    static let fillHover = dynamic(.black.withAlphaComponent(0.06), .white.withAlphaComponent(0.09))
    static let note = dynamic(.black.withAlphaComponent(0.025), .white.withAlphaComponent(0.035))

    static let text = ink(0.9, 0.9)
    static let textMuted = ink(0.7, 0.68)
    static let textSecondary = ink(0.5, 0.48)
    static let textTertiary = ink(0.4, 0.48)
    static let textFaint = ink(0.25, 0.28)

    static func ink(_ light: CGFloat, _ dark: CGFloat) -> Color {
        dynamic(.black.withAlphaComponent(light), .white.withAlphaComponent(dark))
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    static func setupHex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Icons

enum SetupIconElement: Equatable {
    case path(String, CGLineCap, CGLineJoin)
    case circle(CGFloat, CGFloat, CGFloat, CGLineCap, CGLineJoin)
}

/// A Hugeicons outline on its 24-point grid, stroked at `lineWidth` like `<HugeiconsIcon strokeWidth=…>`.
struct SetupIconView: View {
    let icon: SetupIcon
    var size: CGFloat = 22
    var lineWidth: CGFloat = 1.5

    var body: some View {
        let groups = SetupIconShape.styleGroups(icon)
        ZStack {
            ForEach(groups.indices, id: \.self) { index in
                SetupIconShape(elements: groups[index].elements)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 24,
                                               lineCap: groups[index].cap, lineJoin: groups[index].join))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SetupIconShape: Shape {
    let elements: [SetupIconElement]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        for element in elements {
            switch element {
            case .path(let data, _, _): path.addPath(SVGPathData.path(data))
            case .circle(let x, let y, let r, _, _):
                path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        return path.applying(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
            .scaledBy(x: scale, y: scale))
    }

    /// Elements sharing a cap and join are stroked together; SVG draws each with its own.
    static func styleGroups(_ icon: SetupIcon) -> [(cap: CGLineCap, join: CGLineJoin, elements: [SetupIconElement])] {
        var groups: [(cap: CGLineCap, join: CGLineJoin, elements: [SetupIconElement])] = []
        for element in icon.elements {
            let (cap, join): (CGLineCap, CGLineJoin) = switch element {
            case .path(_, let cap, let join), .circle(_, _, _, let cap, let join): (cap, join)
            }
            if let index = groups.firstIndex(where: { $0.cap == cap && $0.join == join }) {
                groups[index].elements.append(element)
            } else {
                groups.append((cap, join, [element]))
            }
        }
        return groups
    }
}

/// SVG path data: M, L, H, V, C, S and Z, absolute or relative, with implicit repeats. Hugeicons use no arcs.
enum SVGPathData {
    static func path(_ data: String) -> Path {
        var path = Path()
        var scanner = Scanner(Array(data.utf8))
        var command: UInt8 = 0
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        while let next = scanner.command(after: command) {
            command = next
            let relative = command >= 0x61
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command | 0x20 {
            case 0x6D: // m
                guard let p = point() else { return path }
                path.move(to: p); current = p; start = p; lastControl = nil
                command = relative ? 0x6C : 0x4C   // further pairs are line-tos
            case 0x6C: // l
                guard let p = point() else { return path }
                path.addLine(to: p); current = p; lastControl = nil
            case 0x68: // h
                guard let x = scanner.number() else { return path }
                current.x = relative ? current.x + x : x; path.addLine(to: current); lastControl = nil
            case 0x76: // v
                guard let y = scanner.number() else { return path }
                current.y = relative ? current.y + y : y; path.addLine(to: current); lastControl = nil
            case 0x63: // c
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case 0x73: // s
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case 0x7A: // z
                path.closeSubpath(); current = start; lastControl = nil
                command = 0
            default:
                return path
            }
        }
        return path
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private mutating func skipSeparators() {
            while index < bytes.count, [0x20, 0x2C, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        /// The next command letter, or the current one again when a number follows (an implicit repeat).
        mutating func command(after current: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) {
                index += 1
                return byte
            }
            return current == 0 ? nil : current
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var seenDot = false, seenDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if (0x30...0x39).contains(byte) { seenDigit = true; index += 1 }
                else if byte == 0x2E, !seenDot { seenDot = true; index += 1 }
                else if (byte == 0x65 || byte == 0x45), seenDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
                } else { break }
            }
            guard seenDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii),
                  let value = Double(text) else { index = begin; return nil }
            return CGFloat(value)
        }
    }
}

// MARK: - Permission state

enum SetupAccessState: Equatable {
    case allowed, notAsked, denied, asking, unavailable

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .notAsked: "Not set up"
        case .denied: "Needs access"
        case .asking: "Asking…"
        case .unavailable: "Not connected"
        }
    }

    var actionTitle: String? {
        switch self {
        case .allowed, .asking: nil
        case .denied: "Open Settings"
        case .notAsked, .unavailable: "Allow"
        }
    }
}

// MARK: - Text

extension Text {
    /// A row's or card's bold title (15 pt, tight).
    func setupTitle(_ size: CGFloat = 15) -> some View {
        font(.system(size: size, weight: .bold)).tracking(-0.025 * size).foregroundStyle(SetupTheme.text)
    }

    /// The quiet line under a title.
    func setupDetail(_ size: CGFloat = 13) -> some View {
        font(.system(size: size)).foregroundStyle(SetupTheme.textSecondary).lineSpacing(1.5)
    }
}

// MARK: - Page structure

/// A page's heading: an extra-bold title, one line about it, a hairline under both.
struct SetupPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .heavy)).tracking(-0.55)
                .foregroundStyle(SetupTheme.text).accessibilityAddTraits(.isHeader)
            Text(subtitle).setupDetail(14).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { SetupTheme.ring.frame(height: 1) }
    }
}

/// A labelled group of rows: a small caps label (with an optional control beside it), the rows 8 points apart.
struct SetupGroup<Content: View, Accessory: View>: View {
    let title: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .center, spacing: 12) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold)).tracking(1.2)
                        .foregroundStyle(SetupTheme.textTertiary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    accessory
                }
            }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

extension SetupGroup where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

// MARK: - Rows

/// A row's leading icon: a 44-point tile, white and lifted while its feature is on, faded while it's off.
struct SetupIconTile: View {
    let icon: SetupIcon
    var active = true

    var body: some View {
        SetupIconView(icon: icon, size: 22, lineWidth: 1.5)
            .foregroundStyle(active ? SetupTheme.text : SetupTheme.textTertiary)
            .frame(width: 44, height: 44)
            .background(active ? SetupTheme.card : SetupTheme.fill,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? SetupTheme.ringStrong : SetupTheme.ring, lineWidth: 1))
            .shadow(color: .black.opacity(active ? 0.04 : 0), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}

/// The surface every row sits on: #FAF9F7, a 16-point corner and a hairline ring; it warms under the pointer when the
/// whole row acts.
struct SetupRowSurface: ViewModifier {
    var hoverable: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoverable && hovered && enabled ? SetupTheme.rowHover : SetupTheme.row,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// A row: a tile, a bold title (with an optional badge after it) over its detail, a control at the trailing edge, and
/// optionally more below the title, aligned with it.
struct SetupRow<Trailing: View, Below: View>: View {
    var icon: SetupIcon?
    var active = true
    let title: String
    var detail: String?
    var badge: SetupBadge?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                if let icon { SetupIconTile(icon: icon, active: active) }
                SetupRowText(title: title, detail: detail, badge: badge)
                Spacer(minLength: 12)
                trailing
            }
            below.padding(.leading, icon == nil ? 0 : 60)
        }
        .modifier(SetupRowSurface(hoverable: false))
    }
}

extension SetupRow where Below == EmptyView {
    init(icon: SetupIcon? = nil, active: Bool = true, title: String, detail: String? = nil, badge: SetupBadge? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.active = active
        self.title = title
        self.detail = detail
        self.badge = badge
        self.trailing = trailing()
        self.below = EmptyView()
    }
}

struct SetupRowText: View {
    let title: String
    let detail: String?
    var badge: SetupBadge?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                Text(title).setupTitle().fixedSize(horizontal: false, vertical: true)
                if let badge { badge }
            }
            if let detail {
                Text(detail).setupDetail().fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch row: clicking anywhere on it flips the switch, as in KLOI. Its tile lights up while it's on.
struct SetupToggleRow<Below: View>: View {
    let icon: SetupIcon
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    @ViewBuilder var below: Below
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Button(action: flip) {
                    HStack(alignment: .center, spacing: 16) {
                        SetupIconTile(icon: icon, active: isOn)
                        SetupRowText(title: title, detail: detail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(SetupSwitchStyle())
            }
            below.padding(.leading, 60)
        }
        .modifier(SetupRowSurface(hoverable: true))
        .accessibilityElement(children: .contain)
    }

    private func flip() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { isOn.toggle() }
    }
}

extension SetupToggleRow where Below == EmptyView {
    init(icon: SetupIcon, title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self._isOn = isOn
        self.below = EmptyView()
    }
}

// MARK: - Controls

/// KLOI's switch: a 54×32 capsule that fills orange, its knob carrying an orange dot when on and a faint × when off.
struct SetupSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SetupSwitchBody(configuration: configuration)
    }
}

private struct SetupSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = configuration.isOn
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? (hovered ? SetupTheme.accentHover : SetupTheme.accent)
                         : (hovered ? SetupTheme.ink(0.11, 0.09) : SetupTheme.ink(0.07, 0.06)))
                .overlay(Capsule().strokeBorder(on ? SetupTheme.accent.opacity(0.2) : SetupTheme.ring, lineWidth: 1))
                .overlay(Capsule().stroke(.black.opacity(0.06), lineWidth: 1).blur(radius: 1).offset(y: 1)
                    .mask(Capsule()))
            ZStack {
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    .shadow(color: .black.opacity(0.24), radius: 1, y: 1)
                Circle().fill(SetupTheme.accent).frame(width: 8, height: 8)
                    .scaleEffect(on ? 1 : 0.5).opacity(on ? 1 : 0)
                SetupCross().stroke(Color.black.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 7, height: 7)
                    .scaleEffect(on ? 0.5 : 1).opacity(on ? 0 : 1)
            }
            .frame(width: 24, height: 24)
            .padding(4)
        }
        .frame(width: 54, height: 32)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { configuration.isOn.toggle() }
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: on)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct SetupCross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// KLOI's buttons. Primary is the black pill (white in dark mode); secondary the white pill with a ring; soft a tinted
/// rounded rectangle; destructive red text.
struct SetupButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, soft, destructive }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        SetupButtonBody(kind: kind, configuration: configuration)
    }
}

private struct SetupButtonBody: View {
    let kind: SetupButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pressed = configuration.isPressed && enabled
        let dark = scheme == .dark
        Group {
            switch kind {
            case .primary:
                configuration.label
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(dark ? Color.black : .white)
                    .padding(.horizontal, 16).frame(minHeight: 36)
                    .background((dark ? Color.white : .black).opacity(hovered && enabled ? (dark ? 0.85 : 0.8) : 1), in: Capsule())
                    .scaleEffect(pressed ? 0.97 : 1)
            case .secondary:
                configuration.label
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SetupTheme.textMuted)
                    .padding(.horizontal, 14).frame(minHeight: 30)
                    .background(hovered && enabled ? SetupTheme.controlHover : SetupTheme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(SetupTheme.ringStrong, lineWidth: 1))
                    .scaleEffect(pressed ? 0.98 : 1)
            case .soft:
                configuration.label
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hovered && enabled ? SetupTheme.text : SetupTheme.ink(0.6, 0.6))
                    .padding(.horizontal, 16).frame(minHeight: 34)
                    .background(hovered && enabled ? SetupTheme.fillHover : SetupTheme.fill,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .scaleEffect(pressed ? 0.98 : 1)
            case .destructive:
                configuration.label
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SetupTheme.danger.opacity(hovered && enabled ? 1 : 0.8))
                    .padding(.horizontal, 12).frame(minHeight: 30)
                    .background(SetupTheme.danger.opacity(hovered && enabled ? 0.1 : 0),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

/// A small status mark. Accent badges are KLOI's orange caps ("ALLOWED", "READY"); neutral ones are its grey chips.
struct SetupBadge: View {
    enum Tone { case accent, neutral }
    let text: String
    var tone: Tone = .accent
    var icon: SetupIcon?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { SetupIconView(icon: icon, size: 12, lineWidth: 2.5) }
            Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8)
        }
        .foregroundStyle(tone == .accent ? SetupTheme.accent : SetupTheme.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tone == .accent ? SetupTheme.accent.opacity(0.1) : SetupTheme.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(tone == .accent ? SetupTheme.accent.opacity(0.2) : SetupTheme.ring, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// The trailing edge of a permission row: the state, or the one action that can change it.
struct SetupAccessControl: View {
    let title: String
    let state: SetupAccessState
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        switch state {
        case .allowed:
            SetupBadge(text: "Allowed", icon: .tick)
        case .asking:
            HStack(spacing: 7) {
                SetupSpinner()
                Text(state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(SetupTheme.textSecondary)
            }
        case .denied, .notAsked, .unavailable:
            if let label = actionLabel ?? state.actionTitle, let action {
                Button(label, action: action)
                    .buttonStyle(SetupButtonStyle(kind: .secondary))
                    .accessibilityLabel("\(label) for \(title)")
            } else {
                SetupBadge(text: state.label, tone: .neutral)
            }
        }
    }
}

/// One permission: what it unlocks, and its state or its action. A denied one says so beside its name.
struct SetupPermissionRow: View {
    let icon: SetupIcon
    let title: String
    let detail: String
    let state: SetupAccessState
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        SetupRow(icon: icon, active: state == .allowed, title: title, detail: detail,
                 badge: state == .denied ? SetupBadge(text: state.label, tone: .neutral) : nil) {
            SetupAccessControl(title: title, state: state, actionLabel: actionLabel, action: action)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(state.label)
    }
}

/// KLOI's loading mark: its refresh outline, turning.
struct SetupSpinner: View {
    var size: CGFloat = 14
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SetupIconView(icon: .refresh, size: size, lineWidth: 2)
            .foregroundStyle(SetupTheme.textSecondary)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("Loading")
    }
}

/// A quiet note in a tinted bar, for what's worth knowing but needs no action.
struct SetupNote: View {
    var icon: SetupIcon = .info
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SetupIconView(icon: icon, size: 14, lineWidth: 1.8).offset(y: 2)
            Text(text).font(.system(size: 12, weight: .medium)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(SetupTheme.ink(0.45, 0.48))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupTheme.note, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A status line inside a row (a result, an error, work in progress).
struct SetupStatusLine: View {
    enum Kind { case success, failure, progress, info }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .progress: SetupSpinner(size: 13)
            case .success: SetupIconView(icon: .tick, size: 14, lineWidth: 2.2).foregroundStyle(SetupTheme.accent)
            case .failure: SetupIconView(icon: .alert, size: 14, lineWidth: 1.8).foregroundStyle(SetupTheme.danger)
            case .info: SetupIconView(icon: .info, size: 14, lineWidth: 1.8).foregroundStyle(SetupTheme.textTertiary)
            }
            Text(text).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind == .failure ? SetupTheme.danger : SetupTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// KLOI's segmented pill (its Monthly / Annual control).
struct SetupSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var isOptionDisabled: (Value) -> Bool = { _ in false }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? SetupTheme.ink(1, 1) : SetupTheme.ink(0.45, 0.45))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule().fill(scheme == .dark ? Color.white.opacity(0.12) : .white)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isOptionDisabled(option.value))
                .opacity(isOptionDisabled(option.value) ? 0.45 : 1)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(SetupTheme.fill, in: Capsule())
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// KLOI's usage card, for a download: what's happening, a large percentage and an orange bar.
struct SetupProgressCard: View {
    let status: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if progress == nil { SetupSpinner(size: 13) }
                Text(status).font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupTheme.textSecondary)
                    .lineLimit(1)
            }
            if let progress {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(progress * 100))").font(.system(size: 24, weight: .bold)).tracking(-0.6)
                        .monospacedDigit().foregroundStyle(SetupTheme.text)
                    Text("%").font(.system(size: 13, weight: .medium)).foregroundStyle(SetupTheme.textTertiary)
                }
                .padding(.top, 14)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dictation-download-percent")
                GeometryReader { geometry in
                    Capsule().fill(SetupTheme.ink(0.06, 0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(SetupTheme.accent)
                                .frame(width: geometry.size.width * min(max(progress, 0), 1))
                        }
                }
                .frame(height: 6)
                .padding(.top, 14)
                .accessibilityIdentifier("dictation-download-progress")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupTheme.row, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
        .animation(.easeOut(duration: 0.5), value: progress)
        .accessibilityIdentifier("dictation-model-status")
    }
}

/// A large card for previews and heroes (KLOI's bento cards): 24-point corners, white on the card, a hairline ring.
struct SetupCard<Content: View>: View {
    var fill: Color = SetupTheme.card
    var padding: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
    }
}

/// A keyboard key drawn like KLOI's: dark, raised, its symbol over its name.
struct SetupKeycap: View {
    let symbol: String
    var name: String?
    var width: CGFloat = 52

    var body: some View {
        VStack(alignment: name == nil ? .center : .leading, spacing: 0) {
            Text(symbol).font(.system(size: name == nil ? 15 : 13, weight: name == nil ? .semibold : .medium))
            if let name {
                Spacer(minLength: 0)
                Text(name).font(.system(size: 10, weight: .medium)).tracking(0.3)
            }
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(name == nil ? 0 : 8)
        .frame(width: width, height: 52, alignment: name == nil ? .center : .topLeading)
        .background(LinearGradient(colors: [.setupHex(0x2A2A2A), .setupHex(0x1A1A1A)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .padding(1)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 3)
    }
}

extension ShapeStyle where Self == Color {
    static func setupHex(_ value: UInt32) -> Color { Color(nsColor: .setupHex(value)) }
}
