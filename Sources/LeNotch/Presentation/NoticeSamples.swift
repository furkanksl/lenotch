import Foundation
import IslandCore

/// The debug panel's and the stills' notifications (sim `ARRIVALS`, `NOTES_SAMPLE`): every shape and level, in turn.
/// The people are invented; the apps are the Mac's own where it has them (their real names and icons).
enum NoticeSamples {
    private static func n(_ id: String, _ app: String, _ name: String, title: String? = nil, subtitle: String? = nil, body: String? = nil,
                          thread: String? = nil, ago: Double = 0, level: NoticeLevel = .active, now: Date) -> Notice {
        Notice(id: "sample-" + id, app: app, appName: name, title: title, subtitle: subtitle, body: body, thread: thread,
               date: now.addingTimeInterval(-ago), level: level)
    }

    /// Sent in turn by the debug panel's Notification button.
    static func arrivals(now: Date) -> [Notice] {
        [
            n("msg", "com.apple.MobileSMS", "Messages", title: "Hannah Park",
              body: "Still on for coffee at 3? Grabbed us a table outside.", thread: "hannah", now: now),
            n("cal", "com.apple.iCal", "Calendar", title: "Product Sync", body: "In 10 minutes · Google Meet", level: .timeSensitive, now: now),
            n("slack", "com.tinyspeck.slackmacgap", "Slack", title: "#launch", body: "Daniel: Build 2.4 is signed and ready to ship",
              thread: "launch", now: now),
            n("mail", "com.apple.mail", "Mail", title: "Claire Bennett", subtitle: "Re: Launch checklist",
              body: "Everything looks good on my end. Ready whenever you are.", now: now),
            n("upd", "com.apple.systempreferences", "System Settings", title: "macOS update is ready to install", now: now),   // a title alone
            n("find", "com.apple.findmy", "Find My", body: "Your AirPods Pro were left behind at Studio", now: now),           // a body alone
            n("store", "com.apple.AppStore", "App Store", title: "3 apps were updated", level: .passive, now: now),             // the center only
            n("rem", "com.apple.reminders", "Reminders", title: "Ship release notes", body: "Today, 4:00 PM", now: now),
        ]
    }

    /// What the stills' center holds: a thread's stack, a person's mail, a title alone.
    static func center(now: Date) -> [Notice] {
        [
            n("sl1", "com.tinyspeck.slackmacgap", "Slack", title: "#launch", body: "Owen: Demo clip is uploaded and ready to review",
              thread: "launch", ago: 12 * 60, now: now),
            n("sl2", "com.tinyspeck.slackmacgap", "Slack", title: "#launch", body: "Hannah: Final landing page copy looks great",
              thread: "launch", ago: 14 * 60, now: now),
            n("m1", "com.apple.mail", "Mail", title: "Claire Bennett", subtitle: "Launch checklist",
              body: "Everything looks good on my end. Ready whenever you are.", ago: 38 * 60, now: now),
            n("s1", "com.apple.systempreferences", "System Settings", title: "macOS update is ready to install", ago: 125 * 60, now: now),
        ]
    }
}
