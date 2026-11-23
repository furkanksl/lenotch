import AppKit
import Carbon.HIToolbox
import IslandCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var surface: NotchSurfaceController?
    #if DEBUG
    private var debugPanel: DebugPanelController?
    #endif
    private let setup = SetupWindowController()
    private let tuning = TuningStore()

    private let args = CommandLine.arguments
    private var askKey: HotKey?
    private var dictationShortcutObserver: NSObjectProtocol?
    private var toolShortcutController: ToolShortcutController?
    private var toolShortcutObserver: NSObjectProtocol?
    private var toolShortcutRecordingObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var openAtLogin = false
    private let notificationReplies = NotificationReplyService()
    private let agentSocket = AgentSocket()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        ToolsDragSelfTest.install()
        #endif
        // A public build opened outside Applications moves there first and opens again (11-11).
        if ApplicationInstaller.moveIfNeeded(arguments: args) { return }
        startApplication()
    }

    private func startApplication() {
        do {
            let renderer = try LiquidRenderer()
            let surface = NotchSurfaceController(renderer: renderer, tuning: tuning)
            self.surface = surface
            #if DEBUG
            debugPanel = DebugPanelController(store: tuning, surface: surface)
            #endif
        } catch {
            NSLog("LeNotch: \(error)")
            NSApp.terminate(nil)
            return
        }
        // No menu bar icon (owner, 11-06): the menu opens on a right-click on the island.
        surface?.contextMenu = { [unowned self] hit in makeMenu(hit) }
        refreshOpenAtLogin()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenAtLogin() }
        }
        if Bundle.main.bundleURL.pathExtension == "app", !args.contains("--no-analytics") {
            Analytics.shared.start()
            Analytics.shared.trackAppLaunch(hasNotch: !(NotchGeometry.current()?.1.isVirtual ?? true))
        }
        if let d = surface?.director {
            d.onNeedsSetup = { [unowned self] in setup.show() }
            d.onToggleDictation = { DictationCoordinator.shared.toggle(trigger: .shortcut) }
            d.usage.start()
            // The shared tool controller owns all configurable keys. Keep only the reserved Chat backup separate.
            configureAskShortcut()
            configureToolShortcuts()
            surface?.keys.onFnKey = { [weak self] action in
                if case .pressed = action, self?.surface?.director.island.context.locked == true { return }
                DictationCoordinator.shared.fnKey(action)
            }
            surface?.keys.onFnAvailability = { available in
                DictationCoordinator.shared.pushToTalkUnavailable = DictationInputSettings().pushToTalk && !available
            }
            configureDictationShortcuts()
            dictationShortcutObserver = NotificationCenter.default.addObserver(forName: .dictationShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configureDictationShortcuts() }
            }
            toolShortcutObserver = NotificationCenter.default.addObserver(forName: .toolShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshToolShortcuts() }
            }
            toolShortcutRecordingObserver = NotificationCenter.default.addObserver(forName: .toolShortcutRecordingChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.configureAskShortcut()
                    self?.configureDictationShortcuts()
                    self?.refreshToolShortcuts()
                }
            }
            // Dictation is the notch's own: it takes the ears while it listens and works.
            DictationCoordinator.shared.onDisplayChange = { d.dictationChanged($0.indicator, transcript: $0.transcript) }
            DesktopTransitionsModel.shared.start()
            let replies = notificationReplies
            d.sendNotificationReply = { notice, text in
                try await replies.send(text: text, to: notice).displayMessage
            }
            // Claude and Codex (phase 2): their hooks write here once Setup's "Watch Claude and Codex" adds them.
            agentSocket.onLine = { d.agentHook($0, reply: $1) }
            HookInstaller.refreshScript()   // an installed hook's script keeps up with updates (our own file only)
            LockWallpaper.shared.recoverIfNeeded()   // the album art left as the wallpaper by a quit mid-swap goes back
            // An update changed our entries' timeouts (a question now waits up to 10 minutes for your pick): rewrite only
            // ours, each file backed up first (11-07, owner: "I should be able to click on the answer here").
            if HookInstaller.needsUpgrade() { try? HookInstaller.install() }
            agentSocket.start()
        }
        if (setup.needed && !args.contains("--no-setup")) || args.contains("--setup") { setup.show() }
        #if DEBUG
        if args.contains("--debug") { debugPanel?.toggle() }
        if args.contains("--spike") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                Spikes.run()
            }
        }
        #endif
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows Setup, the way back in
    /// without a menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setup.show()
        return false
    }

    /// One right-click model (11-06, `2026-11-06-many-bubbles-design.md`): the island's own items first (hide what's under
    /// the pointer, what's running off the island, what's hidden), then the app's.
    private func makeMenu(_ hit: HitRegion?) -> NSMenu {
        let menu = NSMenu()
        for entry in surface?.director.menuEntries(at: hit) ?? [] {
            switch entry {
            case .hide(let p, let title): partyItem(menu, title, p, #selector(hideParty(_:)))
            case .show(let p, let title): partyItem(menu, title, p, #selector(showParty(_:)))
            case .open(let p, let title, let status):
                let item = partyItem(menu, title, p, #selector(openParty(_:)))
                if !status.isEmpty { item.subtitle = status }
            case .header(let title): menu.addItem(.sectionHeader(title: title))
            case .separator: menu.addItem(.separator())
            }
        }
        // Timers start here (11-01 design): the island itself doesn't change.
        let timer = NSMenu()
        for minutes in [1, 5, 10, 25] {
            let item = timer.addItem(withTitle: "\(minutes) min", action: #selector(startTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
        }
        menu.addItem(withTitle: "Timer", action: nil, keyEquivalent: "").submenu = timer
        menu.addItem(withTitle: "Prompter…", action: #selector(showPrompter), keyEquivalent: "").target = self
        let dictation = menu.addItem(withTitle: DictationCoordinator.shared.phase == .recording ? "Finish Dictation" : "Start Dictation",
                                     action: #selector(toggleDictation), keyEquivalent: "")
        dictation.target = self
        dictation.subtitle = ToolShortcutSettings.shared.binding(for: .dictation)?.display
        if DictationCoordinator.shared.canCancel {
            let cancel = menu.addItem(withTitle: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
            cancel.target = self
            cancel.subtitle = "esc"
        }
        if DictationCoordinator.shared.lastTranscript != nil {
            menu.addItem(withTitle: "Copy Last Dictation", action: #selector(copyLastDictation), keyEquivalent: "").target = self
        }
        // Which calendars show (the event, its ball and your day), by account; only once Calendar is allowed.
        if let watcher = MeetingWatcher.shared {
            let choices = watcher.calendarChoices()
            if !choices.isEmpty {
                let cals = NSMenu()
                var account: String?
                for c in choices {
                    if c.account != account {
                        if account != nil { cals.addItem(.separator()) }
                        cals.addItem(.sectionHeader(title: c.account))
                        account = c.account
                    }
                    let item = cals.addItem(withTitle: c.title, action: #selector(toggleCalendar(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = c.id
                    item.state = c.shown ? .on : .off
                    item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                        c.color.setFill(); NSBezierPath(ovalIn: r).fill(); return true
                    }
                }
                cals.addItem(.separator())
                cals.addItem(withTitle: "Show All", action: #selector(showAllCalendars), keyEquivalent: "").target = self
                menu.addItem(withTitle: "Calendars", action: nil, keyEquivalent: "").submenu = cals
            }
        }
        // The music bars follow what's playing, or animate (owner, 11-06).
        let bars = NSMenu()
        for mode in AudioBars.Mode.allCases {
            let item = bars.addItem(withTitle: mode == .realAudio ? "Real Audio" : "Animated", action: #selector(setBars(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = surface?.bars.mode == mode ? .on : .off
        }
        menu.addItem(withTitle: "Music Bars", action: nil, keyEquivalent: "").submenu = bars
        // Which screen, and real or virtual notch (11-11).
        NotchMenu.shared.add(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings", action: #selector(showSetup), keyEquivalent: "").target = self
        #if DEBUG
        if NSEvent.modifierFlags.contains(.option) || CommandLine.arguments.contains("--debug") {
            menu.addItem(withTitle: "Debug Panel", action: #selector(toggleDebug), keyEquivalent: "d").target = self
        }
        #endif
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = openAtLogin ? .on : .off
        // Refresh off the main thread so System Settings changes still sync without blocking menu popup.
        refreshOpenAtLogin(updating: login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall LeNotch…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit LeNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        MeetingWatcher.shared?.setCalendar(id, shown: sender.state != .on)
    }

    @objc private func showAllCalendars() { MeetingWatcher.shared?.showAllCalendars() }

    func applicationWillTerminate(_ notification: Notification) {
        if let toolShortcutObserver { NotificationCenter.default.removeObserver(toolShortcutObserver) }
        if let toolShortcutRecordingObserver { NotificationCenter.default.removeObserver(toolShortcutRecordingObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        ToolShortcutSettings.shared.endRecording()
        toolShortcutController?.stop()
        toolShortcutController = nil
        DesktopTransitionsModel.shared.stop()
        UsageModel.shared.stop()
        askKey?.unregister()
        DictationCoordinator.shared.cancel()
        if let dictationShortcutObserver { NotificationCenter.default.removeObserver(dictationShortcutObserver) }
        LockWallpaper.shared.restoreOnQuit()   // never leave someone's wallpaper behind
        agentSocket.stop()
        surface?.stop()
    }

    private func configureDictationShortcuts() {
        let settings = DictationInputSettings()
        DictationCoordinator.shared.shortcutUnavailable = false
        guard !ToolShortcutSettings.shared.isRecording else {
            surface?.keys.fnPushToTalkEnabled = false
            return
        }
        surface?.keys.fnPushToTalkEnabled = settings.pushToTalk
        updateShortcutAvailability()
    }

    private func configureAskShortcut() {
        askKey?.unregister()
        askKey = nil
        guard !ToolShortcutSettings.shared.isRecording, let director = surface?.director else { return }
        askKey = HotKey(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey | cmdKey) { director.toggleAsk(source: "shortcut") }
    }

    private func configureToolShortcuts() {
        guard let director = surface?.director else { return }
        let controller = ToolShortcutController(settings: .shared)
        controller.start { [weak director] target in director?.toggleToolShortcut(target) }
        toolShortcutController = controller
        updateShortcutAvailability()
    }

    private func refreshToolShortcuts() {
        toolShortcutController?.refresh()
        updateShortcutAvailability()
    }

    private func updateShortcutAvailability() {
        let failures = ToolShortcutSettings.shared.failures
        DictationCoordinator.shared.shortcutUnavailable = failures[.dictation] != nil
        LauncherModel.shared.shortcutUnavailable = failures[.launcher] != nil
    }

    #if DEBUG
    @objc private func toggleDebug() { debugPanel?.toggle() }
    #endif

    @objc private func showSetup() { setup.show() }

    @objc private func showPrompter() { surface?.director.editPrompter(source: "menu") }

    @objc private func toggleDictation() { DictationCoordinator.shared.toggle(trigger: .menu) }
    @objc private func cancelDictation() { DictationCoordinator.shared.cancel() }
    @objc private func copyLastDictation() { DictationCoordinator.shared.copyLastTranscript() }

    @objc private func uninstall() { Uninstaller.confirmAndRun() }

    @objc private func setBars(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = AudioBars.Mode(rawValue: raw) { surface?.bars.mode = mode }
    }

    @objc private func startTimer(_ sender: NSMenuItem) { surface?.director.startTimer(minutes: sender.tag, source: "menu") }

    @discardableResult
    private func partyItem(_ menu: NSMenu, _ title: String, _ p: Party, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = p
        return item
    }

    @objc private func hideParty(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Party { surface?.director.hide(p) }
    }

    @objc private func showParty(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Party { surface?.director.unhide(p) }
    }

    @objc private func openParty(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Party { surface?.director.openCard(p) }
    }

    private func refreshOpenAtLogin(updating item: NSMenuItem? = nil) {
        Task { @MainActor [weak self, weak item] in
            let enabled = await Task.detached(priority: .utility) { SMAppService.mainApp.status == .enabled }.value
            self?.openAtLogin = enabled
            item?.state = enabled ? .on : .off
        }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let wantEnabled = !openAtLogin
        openAtLogin = wantEnabled
        sender.state = wantEnabled ? .on : .off
        Task { @MainActor [weak self] in
            let actual = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    if wantEnabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("LeNotch: launch at login: \(error)")
                }
                return SMAppService.mainApp.status == .enabled
            }.value
            self?.openAtLogin = actual
        }
    }
}
