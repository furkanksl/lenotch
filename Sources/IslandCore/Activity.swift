/// The activities the island can show, with what the simulator says about each one
/// (`ACT` in `sim/src/acts.js`).
public enum ActivityID: String, CaseIterable, Sendable {
    case incoming, call, airpods, charging, battery, timer, meeting, camera, download, messages
    case prompter
    /// Chess (11-06, docs/superpowers/specs/2026-11-06-chess-design.md): the opponent moved while you were elsewhere.
    case chess
    /// A Claude or Codex usage limit, and its reset (11-06, sim `aglimit` / `agback`).
    case agentLimit, agentBack
    /// The lock screen (11-07, docs/superpowers/specs/2026-11-07-lock-screen-design.md): a closed lock and the Touch ID
    /// fingerprint while locked, and the unlock moment (the lock opens, the fingerprint turns into a check).
    case lockScreen, unlocked
    /// Any app's notification (11-07, docs/superpowers/specs/2026-11-07-notifications-design.md): in the ears for a few
    /// seconds, its card opens on hover; the director holds which one (`IslandDirector.notice(for:)`).
    case notice

    /// Shows only in the ears: a press opens nothing.
    public var earsOnly: Bool { self == .lockScreen || self == .unlocked }
}

/// Where an activity goes when it shares the island
/// (`docs/superpowers/specs/2026-11-01-media-context-design.md`).
public enum Tier: Sendable {
    /// Takes the ears and opens itself (unless you're typing); media steps aside until it ends.
    case alert
    /// Takes the ears; media moves to the bubble.
    case live
    /// Waits in the bubble while media plays (ears when nothing plays).
    case ongoing
    /// Borrows the ears for a few seconds, then hands back exactly what was there.
    case transient
}

/// An open card's size in points.
public struct CardSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var radius: Double
    public var halfWidth: Double { width / 2 }

    public init(width: Double, height: Double, radius: Double) {
        self.width = width
        self.height = height
        self.radius = radius
    }
}

public struct ActivitySpec: Sendable {
    public let id: ActivityID
    public let tier: Tier
    /// How far each ear reaches past the notch while this activity holds the ears
    /// (nil: the tuned ear extent).
    public let ear: Double?
    public let card: CardSize
    /// Space above and below the content: 20 for the multi-row cards (and the incoming call), 14 for the
    /// short ones like the iPhone's (owner, 11-01: the short cards were cramped where there's more than one row).
    public var padding: Double {
        switch id {
        case .call, .meeting, .download, .messages, .incoming, .camera, .prompter,
             .chess, .agentLimit, .agentBack, .notice: 20
        default: 14
        }
    }
    /// Seconds a transient stays before it leaves on its own.
    public let transient: Double?
    /// Opens its card by itself when it arrives.
    public let opens: Bool
    /// The liquid shivers on this period (seconds) while it shows (the ringing call).
    public let pulse: Double?
    /// Accent, also the event pulse's colour.
    public let colorHex: String
    /// Its name in the island's menu and the +N list.
    public var title: String {
        switch id {
        case .incoming: "Incoming call"
        case .call: "Call"
        case .airpods: "AirPods"
        case .charging: "Charging"
        case .battery: "Low battery"
        case .timer: "Timer"
        case .prompter: "Prompter"
        case .meeting: "Next meeting"
        case .camera: "Camera"
        case .download: "Download"
        case .messages: "Messages"
        case .chess: "Chess"
        case .agentLimit: "Usage limit"
        case .agentBack: "Limit reset"
        case .lockScreen: "Locked"
        case .unlocked: "Unlocked"
        case .notice: "Notification"
        }
    }
    /// Worth a ball when it isn't in the ears (11-06: downloads never are; they stay in the list and the menu).
    public var ball: Bool { id != .download }

    public static subscript(id: ActivityID) -> ActivitySpec { all[id]! }

    private static let all: [ActivityID: ActivitySpec] = {
        let green = "#30D158", orange = "#FF9F0A", red = "#FF453A"
        let specs: [ActivitySpec] = [
            ActivitySpec(id: .incoming, tier: .alert, ear: 96,
                         card: CardSize(width: 372, height: 84, radius: 42), transient: nil, opens: true,
                         pulse: 1.1, colorHex: green),
            ActivitySpec(id: .call, tier: .live, ear: 80,
                         card: CardSize(width: 372, height: 140, radius: 40), transient: nil, opens: false,
                         pulse: nil, colorHex: green),
            ActivitySpec(id: .airpods, tier: .transient, ear: nil,
                         card: CardSize(width: 372, height: 120, radius: 40), transient: 5, opens: false,
                         pulse: nil, colorHex: "#E8F0FF"),
            ActivitySpec(id: .charging, tier: .transient, ear: 120,
                         card: CardSize(width: 372, height: 102, radius: 40), transient: 4, opens: false,
                         pulse: nil, colorHex: green),
            // Low battery at 20% and 10% (11-01 design): a red transient laid out like Charging.
            ActivitySpec(id: .battery, tier: .transient, ear: 120,
                         card: CardSize(width: 372, height: 102, radius: 40), transient: 5, opens: false,
                         pulse: nil, colorHex: red),
            ActivitySpec(id: .timer, tier: .ongoing, ear: nil,
                         card: CardSize(width: 372, height: 94, radius: 40), transient: nil, opens: false,
                         pulse: nil, colorHex: orange),
            ActivitySpec(id: .prompter, tier: .live, ear: 76,
                         card: CardSize(width: 500, height: 332, radius: 40), transient: nil, opens: true,
                         pulse: nil, colorHex: green),
            ActivitySpec(id: .meeting, tier: .ongoing, ear: 80,
                         card: CardSize(width: 372, height: 126, radius: 40), transient: nil, opens: false,
                         pulse: nil, colorHex: "#0A84FF"),
            // The camera is on (11-01 design, the filming indicator): waits in the bubble while music plays.
            ActivitySpec(id: .camera, tier: .ongoing, ear: 80,
                         card: CardSize(width: 372, height: 84, radius: 42), transient: nil, opens: false,
                         pulse: nil, colorHex: green),
            ActivitySpec(id: .download, tier: .ongoing, ear: nil,
                         card: CardSize(width: 372, height: 142, radius: 40), transient: nil, opens: false,
                         pulse: nil, colorHex: "#64D2FF"),
            ActivitySpec(id: .messages, tier: .transient, ear: 96,
                         card: CardSize(width: 372, height: 146, radius: 40), transient: 6, opens: false,
                         pulse: nil, colorHex: green),
            // Chess: live while your clock runs (as time-critical as a call).
            ActivitySpec(id: .chess, tier: .live, ear: 100,
                         card: CardSize(width: 372, height: 140, radius: 40), transient: nil, opens: false,
                         pulse: nil, colorHex: "#FFD60A"),
            ActivitySpec(id: .agentLimit, tier: .transient, ear: 112,
                         card: CardSize(width: 372, height: 84, radius: 42), transient: 5, opens: false,
                         pulse: nil, colorHex: red),
            ActivitySpec(id: .lockScreen, tier: .live, ear: 56,
                         card: CardSize(width: 372, height: 84, radius: 42), transient: nil, opens: false,
                         pulse: nil, colorHex: "#FFFFFF"),
            ActivitySpec(id: .unlocked, tier: .transient, ear: 56,
                         card: CardSize(width: 372, height: 84, radius: 42), transient: 1.3, opens: false,
                         pulse: nil, colorHex: green),
            // Compact notification detail reserves room for native reply entry and submission feedback.
            ActivitySpec(id: .notice, tier: .transient, ear: 96,
                         card: CardSize(width: 420, height: 206, radius: 36), transient: 6, opens: true,
                         pulse: nil, colorHex: "#0A84FF"),
            ActivitySpec(id: .agentBack, tier: .transient, ear: 112,
                         card: CardSize(width: 372, height: 84, radius: 42), transient: 4, opens: false,
                         pulse: nil, colorHex: green),
        ]
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
    }()
}

/// The per-app context rules, as data keyed by bundle ID.
public enum AppRules {
    /// Browsers: a player in one is on a tab, not the whole app.
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.operasoftware.Opera", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
    ]

    /// Frontmost, these mean you're presenting: transients stay off and names and texts are hidden.
    public static let presenting: Set<String> = [BundleID.keynote]

    /// The activities an app shows itself: while it's frontmost they leave the island, as iPhone hides
    /// a Live Activity while its app is open (an alert stays). Media leaves while its player is in front.
    public static let hosts: [String: Set<ActivityID>] = [
        BundleID.faceTime: [.incoming, .call],
        BundleID.calendar: [.meeting],
        BundleID.safari: [.download],
        BundleID.messages: [.messages],
    ]

    public static func hosts(_ app: String, _ id: ActivityID) -> Bool { hosts[app]?.contains(id) ?? false }
}

/// Bundle IDs the context rules key on.
public enum BundleID {
    public static let finder = "com.apple.finder"
    public static let music = "com.apple.Music"
    public static let faceTime = "com.apple.FaceTime"
    public static let safari = "com.apple.Safari"
    public static let keynote = "com.apple.iWork.Keynote"
    public static let messages = "com.apple.MobileSMS"
    public static let calendar = "com.apple.iCal"
}
