import AppKit
import IslandCore
import SwiftUI

/// Notifications in the notch (11-07, sim `ACT.notice`, `noteCard`, `noteRow`): the app's icon and who it's from in the
/// ears, and the card it arrives as (laid out like Messages: × and Open in <App> where its reply sits). Every field may
/// be missing; the app's name stands in.

/// The app's own icon, or a bell on a plain tile for an app that isn't on this Mac.
struct NoticeIcon: View {
    let app: String
    let size: Double

    var body: some View {
        if let icon = AppIcons.icon(for: app) {
            // macOS icons carry a margin: drawn a little larger, the tile fills the size like iOS's.
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: size * 1.2, height: size * 1.2)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bell.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(.white.opacity(0.18)))
        }
    }
}

/// The line under the bold one: the subject in semibold, then the text; with neither, the app's name, dimmed.
struct NoticeText: View {
    let notice: Notice
    var font: Font = IslandType.body

    var body: some View {
        if notice.hasText {
            (Text(notice.subtitle.map { $0 + " " } ?? "").fontWeight(.semibold).foregroundStyle(.white.opacity(0.9))
             + Text(notice.body ?? "").foregroundStyle(.white.opacity(0.85)))
                .font(font)
        } else if notice.title != nil {
            Text(notice.appName).font(font).foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// When it came, or that it can't wait (iOS's "Time Sensitive" in the banner's place for the time).
struct NoticeWhen: View {
    let notice: Notice
    let now: Date
    var font: Font = IslandType.secondary

    var body: some View {
        switch notice.level {
        case .critical: Text("Critical").font(font.weight(.semibold)).foregroundStyle(IslandColor.red)
        case .timeSensitive: Text("Time Sensitive").font(font).foregroundStyle(IslandColor.orange)
        default: Text(Self.ago(notice.date, now: now)).font(font).foregroundStyle(IslandColor.dim)
        }
    }

    static func ago(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        return m < 1 ? "now" : m < 60 ? "\(m)m ago" : m < 24 * 60 ? "\(m / 60)h ago" : "Yesterday"
    }
}

/// The ears: the app's icon left, the bold line right (a name, a group, an event).
struct NoticeEar: View {
    let notice: Notice
    let side: EarSide
    @Environment(\.presenting) private var presenting

    var body: some View {
        if side == .left {
            NoticeIcon(app: notice.app, size: 22).entrance(side, 0)
        } else {
            // The whole title if it fits, else its first word (a person's first name, like the sim), else cut short.
            let full = presenting ? notice.appName : notice.head
            let first = full.split(separator: " ").first.map(String.init) ?? full
            ViewThatFits(in: .horizontal) {
                Text(full).fixedSize()
                Text(first).fixedSize()
                Text(full)
            }
            .font(IslandType.ear)
            .frame(maxWidth: 66, alignment: .trailing).entrance(side, 0)
        }
    }
}

/// The newest card stays compact. Its count opens the session-only, scrollable notification column.
struct NoticeCard: View {
    let notice: Notice
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        if director.notificationInbox.expanded {
            NotificationHistoryView(director: director) { director.expandNotices(false) }
        } else {
            NoticeDetailView(notice: notice, director: director)
        }
    }
}

struct NoticeDetailView: View {
    let notice: Notice
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    private var inbox: NotificationInbox { director.notificationInbox }
    private var replySupported: Bool {
        NotificationReplyService.supports(notice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(notice.appName.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(IslandColor.dim)
                Spacer()
                if inbox.items.count > 1 {
                    Button { director.expandNotices(true) } label: {
                        Label("\(inbox.items.count)", systemImage: "square.stack.3d.up")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Show all \(inbox.items.count) notifications")
                }
                NoticeWhen(notice: notice, now: director.date())
            }
            HStack(alignment: .top, spacing: 12) {
                NoticeIcon(app: notice.app, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presenting ? notice.appName : notice.head).font(IslandType.title).lineLimit(1)
                    Group {
                        if presenting { Text("Content hidden while presenting").font(IslandType.body).foregroundStyle(IslandColor.dim) }
                        else { NoticeText(notice: notice) }
                    }
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if inbox.composing && !presenting {
                NoticeReplyComposer(director: director)
            } else {
                HStack(spacing: 8) {
                    RoundButton(symbol: "xmark", style: .gray, size: 30, label: "Dismiss notification") { director.dismissNotice(notice) }
                    if replySupported && !presenting {
                        Button { director.beginNoticeReply(notice) } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                                .font(IslandType.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 30)
                                .foregroundStyle(.black).background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Reply to this notification")
                    }
                    Button { director.openNotice(notice) } label: {
                        Text("Open \(notice.appName)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .disabled(inbox.submitting)
            }
            if let feedback = inbox.feedback {
                Text(feedback).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2).help(feedback)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .background(alignment: .bottom) {
            if inbox.items.count > 1 && !inbox.composing {
                RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.13), lineWidth: 1)
                    .frame(height: 5).padding(.horizontal, 15).offset(y: 8)
            }
        }
    }
}

private struct NoticeReplyComposer: View {
    let director: IslandDirector
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var inbox = director.notificationInbox
        HStack(spacing: 8) {
            TextField("Reply…", text: $inbox.draft)
                .textFieldStyle(.plain).font(IslandType.body).focused($focused)
                .padding(.horizontal, 12).frame(height: 34)
                .background(.white.opacity(0.12), in: Capsule())
                .onSubmit { director.submitNoticeReply() }
                .accessibilityLabel("Reply text")
            Button { director.submitNoticeReply() } label: {
                Group {
                    if inbox.submitting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black) }
                }
                .frame(width: 34, height: 34).background(.white, in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Submit reply")
            .disabled(inbox.submitting || inbox.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inbox.draft.count > 4000)
            Button { director.cancelNoticeReply() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 30)
            }
            .buttonStyle(.plain).accessibilityLabel("Cancel reply").disabled(inbox.submitting)
        }
        .disabled(inbox.submitting)
        .task { focused = true }
        .onChange(of: inbox.submitting) { _, submitting in
            focused = !submitting && inbox.composing
        }
        .onExitCommand { director.cancelNoticeReply() }
    }
}

struct NotificationHistoryView: View {
    let director: IslandDirector
    let onBack: () -> Void
    @Environment(\.presenting) private var presenting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                RoundButton(symbol: "chevron.left", style: .gray, size: 26, label: "Back") { onBack() }
                Text("Notifications").font(IslandType.title)
                Text("\(director.notificationInbox.items.count)").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandColor.dim)
                Spacer()
                Button("Clear") { director.clearNotificationInbox() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(IslandColor.dim)
                    .disabled(director.notificationInbox.submitting || director.notificationInbox.items.isEmpty)
            }
            if director.notificationInbox.items.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "bell").font(.system(size: 25)).foregroundStyle(IslandColor.dim)
                    Text("You're all caught up").font(IslandType.body)
                    Text(NotificationStore.enabled ? "New notifications will appear here." : "Enable Notifications in Setup to get started.")
                        .font(.system(size: 11)).foregroundStyle(IslandColor.dim).multilineTextAlignment(.center)
                    if !NotificationStore.enabled {
                        Button("Open Setup") { director.onNeedsSetup?() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(director.notificationInbox.items) { notice in
                            Button {
                                director.selectInboxNotice(notice)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    NoticeIcon(app: notice.app, size: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(presenting ? notice.appName : notice.head).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                            Spacer(minLength: 4)
                                            NoticeWhen(notice: notice, now: director.date(), font: .system(size: 10))
                                        }
                                        if !presenting { NoticeText(notice: notice, font: .system(size: 11)).lineLimit(2) }
                                        else { Text("Content hidden while presenting").font(.system(size: 11)).foregroundStyle(IslandColor.dim) }
                                    }
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(IslandColor.dim)
                                }
                                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            }
                            .buttonStyle(.plain).disabled(director.notificationInbox.submitting)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            Text("This session only · Clear dismisses from LeNotch, not Notification Center")
                .font(.system(size: 9)).foregroundStyle(IslandColor.dim).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}
