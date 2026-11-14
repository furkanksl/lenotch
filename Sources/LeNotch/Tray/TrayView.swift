import AppKit
import EventKit
import IslandCore
import SwiftUI
import UniformTypeIdentifiers

/// The tray's tools on the open card (sim `#tray`): the whole card on the empty notch, or a column beside the
/// player (a hairline between them, 12 pt past the player's 20 pt margin). The column is 128 pt tall between
/// 20 pt margins; it lays out at the card's final size and rides the spring like every card.
struct TrayLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let card: CardSize
    let withPlayer: Bool
    let playerWidth: Double

    var body: some View {
        CardPlacement(frame: frame, card: card) {
            let left = withPlayer ? playerWidth + 4 : 20
            ZStack(alignment: .topLeading) {
                if withPlayer {
                    Rectangle().fill(.white.opacity(0.1))
                        .frame(width: 1, height: card.height - 56)
                        .offset(x: playerWidth - 8, y: 28)
                }
                TrayPages(tray: director.tray, director: director)
                    .frame(width: max(card.width - left - 20, 0), height: card.height - 40, alignment: .topLeading)
                    .offset(x: left, y: 20)
            }
            .frame(width: card.width, height: card.height, alignment: .topLeading)
            .foregroundStyle(.white)
        }
    }
}

/// The grid, or one tool's page sliding in over it.
private struct TrayPages: View {
    let tray: TrayModel
    let director: IslandDirector
    @Environment(\.islandMotion) private var motion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch tray.page {
                case .main: TrayGrid(tray: tray, director: director)
                case .timer: TimerPage(tray: tray, director: director)
                case .clipboard: ClipboardPage(tray: tray)
                case .shelf: ShelfPage(tray: tray)
                case .shortcuts: ShortcutsPage(tray: tray)
                case .today: DayPage(tray: tray, director: director)
                case .prompter: PrompterPage(tray: tray, director: director)
                }
            }
            .id(tray.page)
            .transition(motion.reduce ? .opacity : .opacity.combined(with: .offset(x: 10)))
        }
        .animation(motion.stills ? nil : .spring(response: motion.seconds(0.3), dampingFraction: 0.85), value: tray.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Grid

/// Two rows of tools: 40 pt circles with 11 pt labels, the rows 10 pt apart.
private struct TrayGrid: View {
    let tray: TrayModel
    let director: IslandDirector

    var body: some View {
        let timer = director.trayTimerLeft
        let running = director.trayRunning
        // Prompter joins the existing tools; Today opens the calendar page without another navigation layer.
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                // Text-only Quick Ask (⌥Space).
                Tool(icon: .ask, label: "Ask") { director.openAsk() }
                    .help("Ask Claude or ChatGPT (⌥Space)")
                Tool(icon: .timer, label: timer.map(clockText) ?? "Timer", tint: timer != nil ? IslandColor.orange : nil) { tray.go(.timer) }
                Tool(icon: .prompter, label: "Prompter", tint: director.prompter.phase == .playing ? IslandColor.green : nil) { tray.go(.prompter) }
                Tool(icon: .today, label: "Today") { tray.go(.today) }
            }
            HStack(spacing: 0) {
                Tool(icon: running ? .pause : .play, label: running ? "Pause" : "Play") { director.trayPause() }
                    .disabled(!director.trayCanPause)
                Tool(icon: .clipboard, label: "Clipboard") { tray.go(.clipboard) }
                Tool(icon: .shelf, label: "Shelf", badge: tray.files.isEmpty ? nil : tray.files.count) { tray.go(.shelf) }
                Tool(icon: .shortcuts, label: "Shortcuts") { tray.go(.shortcuts) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrompterPage: View {
    let tray: TrayModel
    let director: IslandDirector

    var body: some View {
        let model = director.prompter
        Page(tray: tray, title: "Prompter", action: ("Edit scripts", { director.editPrompter() })) {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 18)).foregroundStyle(IslandColor.green)
                    .frame(width: 40, height: 40).background(.white.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.canPlay ? model.title : "Your words, by the camera")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(model.canPlay ? "\(model.text.split(whereSeparator: \.isWhitespace).count) words · \(Int(model.speed)) pt/s" : "Write a script, then read from the notch.")
                        .font(.system(size: 11)).foregroundStyle(IslandColor.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if model.canPlay { director.startPrompter() } else { director.editPrompter() }
                } label: {
                    Image(systemName: model.canPlay ? "play.fill" : "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 38, height: 38)
                        .foregroundStyle(.black).background(IslandColor.green, in: Circle())
                }
                .buttonStyle(PressScaleStyle())
                .help(model.canPlay ? "Start prompting" : "Write your first script")
                .accessibilityLabel(model.canPlay ? "Start prompting" : "Write a script")
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct Tool: View {
    let icon: ToolIcon
    let label: String
    var tint: Color?
    var badge: Int?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ToolIconView(icon: icon)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                    .foregroundStyle(tint ?? .white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(tint.map { $0.opacity(0.3) } ?? .white.opacity(0.14)))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text("\(badge)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(.white))
                                .offset(x: 8, y: -4)
                        }
                    }
                    .opacity(enabled ? 1 : 0.4)
                Text(label).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(enabled ? 0.65 : 0.33))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Pages

/// A tool's page: back, the title, an optional action; the body below fills the rest.
private struct Page<Content: View>: View {
    let tray: TrayModel
    let title: String
    var action: (label: String, run: () -> Void)?
    var status: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { tray.go(.main) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let status {
                        Text(status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .help(status ?? title)
                Spacer(minLength: 4)
                if let action {
                    Button(action.label, action: action.run).buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(height: 28)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Two by two, 8 pt apart, filling the page's body.
private struct Pills<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) { content }
    }
}

private struct Pill<Icon: View>: View {
    let label: String
    var on = false
    var centred = false
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @State var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(label).lineLimit(1).minimumScaleFactor(0.85)
                if !centred { Spacer(minLength: 0) }
            }
            .font(.system(size: centred ? 15 : 13, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? IslandColor.indigo.opacity(0.32) : .white.opacity(over ? 0.16 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.95, hover: 1))
        .onHover { over = $0 }
    }
}

/// Your day, at the lyrics player's size (a click on the event card): what's on now on the left (its time left large, how
/// far it has gone, what's next), the day's events on the right, scrolled to now. Titles hide while presenting.
private struct DayPage: View {
    let tray: TrayModel
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let _ = director.now
        let now = director.date()
        let timed = director.agenda.filter { !$0.allDay }
        Page(tray: tray, title: now.formatted(.dateTime.weekday(.wide).day().month()),
             action: (label: "Calendar", run: { NSWorkspace.shared.open(URL(string: "ical://")!) })) {
            if director.agenda.isEmpty {
                Text(EKEventStore.authorizationStatus(for: .event) == .fullAccess ? "Nothing on today" : "Allow Calendar in Setup to see your day")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    current(timed.last { $0.isNow(now) }, next: timed.first { $0.start > now }, now: now)
                        .frame(width: 236)
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
                    DayList(items: director.agenda, now: now, presenting: presenting)
                }
                .padding(.top, 6)
            }
        }
    }

    private func title(_ e: AgendaItem) -> String { presenting ? "Event" : e.title }

    @ViewBuilder private func current(_ e: AgendaItem?, next: AgendaItem?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e {
                let gone = min(max(now.timeIntervalSince(e.start) / max(e.end.timeIntervalSince(e.start), 60), 0), 1)
                let left = e.end.timeIntervalSince(now)
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: e.colorHex)).frame(width: 3, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(e)).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Text(span(e) + (e.calendar.isEmpty ? "" : " · \(e.calendar)"))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(durationText(left)).font(.system(size: 34, weight: .semibold).monospacedDigit())
                        .foregroundStyle(left <= 300 ? IslandColor.red : .white)
                        .contentTransition(.numericText())
                    Text("left").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                LineBar(progress: gone, tint: left <= 300 ? IslandColor.red : Color(hex: e.colorHex))
                    .frame(height: 5).padding(.top, 8)
            } else {
                Text("Nothing on now").font(.system(size: 17, weight: .semibold))
                Text(next.map { "Free until \($0.start.formatted(date: .omitted, time: .shortened))" } ?? "Free for the rest of the day")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
            }
            Spacer(minLength: 10)
            if let next {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: next.colorHex)).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(next)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("Next, in \(durationText(next.start.timeIntervalSince(now)))")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The day's events: all-day ones on top, then each timed one by its start time; past ones fade, the one on now is lit.
private struct DayList: View {
    let items: [AgendaItem]
    let now: Date
    let presenting: Bool

    var body: some View {
        let timed = items.filter { !$0.allDay }
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.filter(\.allDay)) { e in
                        row(e, time: "All day", on: false, past: false)
                    }
                    ForEach(timed) { e in
                        row(e, time: e.start.formatted(date: .omitted, time: .shortened), on: e.isNow(now), past: e.end <= now)
                    }
                }
            }
            .onAppear {
                if let target = timed.first(where: { $0.isNow(now) }) ?? timed.first(where: { $0.start > now }) {
                    proxy.scrollTo(target.id, anchor: .top)
                }
            }
        }
    }

    private func row(_ e: AgendaItem, time: String, on: Bool, past: Bool) -> some View {
        HStack(spacing: 10) {
            Text(time).font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(on ? 0.9 : 0.45))
                .frame(width: 58, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: e.colorHex)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(presenting ? "Event" : e.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                Text(e.allDay ? e.calendar : "until \(e.end.formatted(date: .omitted, time: .shortened))" + (e.calendar.isEmpty ? "" : " · \(e.calendar)"))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(on ? 0.1 : 0)))
        .opacity(past ? 0.4 : 1)
        .id(e.id)
    }
}

private func span(_ e: AgendaItem) -> String {
    "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
}

/// "45m", "1h 10m": a stretch of time, rounded up to the minute.
func durationText(_ seconds: TimeInterval) -> String {
    let minutes = max(Int((seconds / 60).rounded(.up)), 0)
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

/// A thin progress bar, as the brightness HUD's: a dim track, the filled part in the tint.
struct LineBar: View {
    let progress: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(geo.size.height, geo.size.width * min(max(progress, 0), 1)))
                }
        }
    }
}

private struct TimerPage: View {
    let tray: TrayModel
    let director: IslandDirector

    var body: some View {
        Page(tray: tray, title: "Timer") {
            Pills {
                ForEach([1, 5, 10, 25], id: \.self) { m in
                    Pill(label: "\(m) min", centred: true) { EmptyView() } action: { director.startTimer(minutes: m) }
                }
            }
        }
    }
}

private struct ShortcutsPage: View {
    let tray: TrayModel
    private static let colors = [IslandColor.orange, IslandColor.cyan, IslandColor.green, IslandColor.red]

    var body: some View {
        let names = tray.pinnedShortcuts
        Page(tray: tray, title: "Shortcuts") {
            if tray.shortcuts == nil {
                Empty(text: "Loading…")
            } else if names.isEmpty {
                Empty(text: "No shortcuts yet")
            } else {
                Pills {
                    ForEach(Array(names.enumerated()), id: \.element) { i, name in
                        let done = tray.done == "sc\(name)"
                        Pill(label: name) {
                            Image(systemName: done ? "checkmark" : "square.on.square")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(done ? IslandColor.green : Self.colors[i % Self.colors.count]))
                        } action: { tray.run(name) }
                    }
                }
            }
        }
    }
}

private struct ClipboardPage: View {
    let tray: TrayModel
    @Environment(\.presenting) private var presenting

    var body: some View {
        Page(tray: tray, title: "Clipboard", action: tray.clips.isEmpty ? nil : ("Clear", { tray.clearClips() })) {
            if tray.clips.isEmpty {
                Empty(text: "Nothing copied yet")
            } else {
                VStack(spacing: 6) {
                    ForEach(tray.clips.prefix(3)) { clip in
                        Button { tray.copy(clip) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: clip.isLink ? "link" : "text.alignleft")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(width: 15)
                                // Presenting: what was copied stays private.
                                Text(presenting ? "Copied text" : clip.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if tray.done == "clip\(clip.id)" {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(IslandColor.green)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle(pressed: 0.97, hover: 1))
                    }
                }
            }
        }
    }
}

private struct ShelfPage: View {
    let tray: TrayModel

    var body: some View {
        Page(tray: tray, title: "Shelf", action: tray.files.isEmpty ? nil : ("Clear", { tray.clearFiles() })) {
            if tray.files.isEmpty {
                Empty(text: "Drop files on the notch", dashed: true)
            } else {
                let shown = Array(tray.files.prefix(4)), more = tray.files.count - shown.count
                HStack(spacing: 6) {
                    ForEach(shown, id: \.self) { ShelfTile(url: $0) }
                    if more > 0 {
                        Text("+\(more)").font(.system(size: 13, weight: .semibold))
                            .frame(width: 40, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
                            .frame(width: 60)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A file on the shelf: its Finder icon and name. Drag it out to put it somewhere; click to open it.
private struct ShelfTile: View {
    let url: URL
    @State var over = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 56)
        }
        .frame(width: 60).frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(over ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { over = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .accessibilityLabel(url.lastPathComponent)
    }
}

private struct Empty: View {
    let text: String
    var dashed = false

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
    }
}
