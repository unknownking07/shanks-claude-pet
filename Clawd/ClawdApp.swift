import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

@main
struct ClawdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ClawdController?
    var statusItem: NSStatusItem?
    var signInWindowController: ClaudeSignInWindowController?

    // Bundle IDs we treat as "a Claude session is active". When any of these are running,
    // the pet window is visible; when none are, the pet hides (menu bar icon stays).
    private static let claudeBundleIDs: Set<String> = [
        "com.anthropic.claude",       // Claude Desktop chat app
        "com.anthropic.claudefordesktop",  // older bundle id variant
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestNotificationAuthorization()
        HookInstaller.install()
        controller = ClawdController()
        controller?.start()
        setupMenuBar()
        observeClaudeAppLifecycle()
        applyInitialPetVisibility()
    }

    private func observeClaudeAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.claudeBundleIDs.contains(bid) else { return }
            self?.showPet(reason: "claude.app launched")
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.claudeBundleIDs.contains(bid) else { return }
            // Only hide if no other claude-family app is still running
            let stillRunning = NSWorkspace.shared.runningApplications.contains {
                guard let id = $0.bundleIdentifier else { return false }
                return Self.claudeBundleIDs.contains(id) && $0.processIdentifier != app.processIdentifier
            }
            if !stillRunning {
                self?.hidePet(reason: "claude.app terminated")
            }
        }
    }

    private func isClaudeAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            guard let id = $0.bundleIdentifier else { return false }
            return Self.claudeBundleIDs.contains(id)
        }
    }

    private func applyInitialPetVisibility() {
        if isClaudeAppRunning() {
            showPet(reason: "claude.app already running at launch")
        } else {
            hidePet(reason: "no claude.app at launch")
        }
    }

    private func showPet(reason: String) {
        guard let cat = controller?.cat else { return }
        NSLog("[Shanks] showing pet — %@", reason)
        cat.window.orderFrontRegardless()
        cat.resumeCommentSchedule()
    }

    private func hidePet(reason: String) {
        guard let cat = controller?.cat else { return }
        NSLog("[Shanks] hiding pet — %@", reason)
        cat.window.orderOut(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.cat.hookServer.stop()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 36)
        if let button = statusItem?.button,
           let url = Bundle.module.url(forResource: "ShanksIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 28, height: 28)
            image.isTemplate = false
            button.image = image
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Hide Shanks", action: #selector(toggleVisibility(_:)), keyEquivalent: "c")
        toggleItem.state = .on
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let commentMenu = NSMenu()
        let commentToggle = NSMenuItem(title: "Enabled", action: #selector(toggleComments(_:)), keyEquivalent: "")
        commentToggle.state = .on
        commentMenu.addItem(commentToggle)
        commentMenu.addItem(NSMenuItem.separator())
        for (secs, label) in [(300, "Every 5 min"), (900, "Every 15 min"), (1800, "Every 30 min"), (3600, "Every 1 hr"), (7200, "Every 2 hr")] {
            let item = NSMenuItem(title: label, action: #selector(setCommentInterval(_:)), keyEquivalent: "")
            item.representedObject = secs
            item.state = Int(CatCharacter.commentInterval) == secs ? .on : .off
            commentMenu.addItem(item)
        }
        let commentItem = NSMenuItem(title: "Screen Comments", action: nil, keyEquivalent: "")
        commentItem.submenu = commentMenu
        menu.addItem(commentItem)

        let emotionMenu = NSMenu()
        let emotions: [(String, String)] = [
            ("😄 Happy", "😄"),
            ("😭 Sad", "😭"),
            ("😡 Angry", "😡"),
            ("😨 Fear", "😨"),
            ("🤢 Disgust", "🤢"),
            ("😴 Sleepy", "😴"),
            ("😍 Love", "😍"),
        ]
        for (label, id) in emotions {
            let item = NSMenuItem(title: label, action: #selector(playEmotion(_:)), keyEquivalent: "")
            item.representedObject = id
            emotionMenu.addItem(item)
        }
        let emotionItem = NSMenuItem(title: "Emotions", action: nil, keyEquivalent: "")
        emotionItem.submenu = emotionMenu
        menu.addItem(emotionItem)

        menu.addItem(NSMenuItem.separator())

        let launchAtLoginItem = NSMenuItem(title: "Launch on Login", action: #selector(toggleLaunchOnLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.state = isLaunchOnLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let signInItem = NSMenuItem(title: "Sign In to Claude", action: #selector(signInToClaude(_:)), keyEquivalent: "")
        signInItem.target = self
        menu.addItem(signInItem)

        let signOutItem = NSMenuItem(title: "Sign Out Claude", action: #selector(signOutClaude(_:)), keyEquivalent: "")
        signOutItem.target = self
        menu.addItem(signOutItem)

        menu.addItem(NSMenuItem.separator())

        let checkUsageItem = NSMenuItem(title: "Check Usage", action: #selector(checkUsage(_:)), keyEquivalent: "")
        checkUsageItem.target = self
        menu.addItem(checkUsageItem)

        let wakeItem = NSMenuItem(title: "Wake Up Shanks", action: #selector(wakeUpCat(_:)), keyEquivalent: "")
        wakeItem.target = self
        menu.addItem(wakeItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc func toggleVisibility(_ sender: NSMenuItem) {
        guard let cat = controller?.cat else { return }
        if cat.window.isVisible {
            cat.window.orderOut(nil)
            cat.commentTimer?.invalidate()
            cat.commentTimer = nil
            sender.state = .off
            sender.title = "Show Shanks"
        } else {
            cat.window.orderFrontRegardless()
            cat.resumeCommentSchedule()
            sender.state = .on
            sender.title = "Hide Shanks"
        }
    }

    @objc func toggleComments(_ sender: NSMenuItem) {
        guard let cat = controller?.cat else { return }
        if cat.commentTimer != nil {
            cat.commentTimer?.invalidate()
            cat.commentTimer = nil
            sender.state = .off
        } else {
            cat.resumeCommentSchedule()
            sender.state = .on
        }
    }

    @objc func setCommentInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        CatCharacter.commentInterval = Double(secs)
        if let menu = sender.menu {
            for item in menu.items where item.action == #selector(setCommentInterval(_:)) {
                item.state = (item.representedObject as? Int) == secs ? .on : .off
            }
        }
        // Reschedule quietly — no launch opener
        if let cat = controller?.cat, cat.commentTimer != nil {
            cat.resumeCommentSchedule()
        }
    }

    @objc func playEmotion(_ sender: NSMenuItem) {
        guard let cat = controller?.cat, let emoji = sender.representedObject as? String else { return }
        cat.triggerEmotion(emoji)
    }

    // MARK: - Launch on Login

    private var isLaunchOnLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc func toggleLaunchOnLogin(_ sender: NSMenuItem) {
        do {
            if isLaunchOnLoginEnabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("[LaunchOnLogin] Failed: %@", error.localizedDescription)
            // Reflect actual state after failure
            sender.state = isLaunchOnLoginEnabled ? .on : .off
        }
    }

    private func requestNotificationAuthorization() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc func signOutClaude(_ sender: NSMenuItem) {
        UsageAPIClient.clearSavedSession()
        controller?.cat.showPreview("claude session walked the plank", autoFade: true)
    }

    @objc func signInToClaude(_ sender: NSMenuItem) {
        signInWindowController = ClaudeSignInWindowController { [weak self] success in
            let message = success ? "claude session locked in, cap'n" : "claude sign-in went under, try again"
            self?.controller?.cat.showPreview(message, autoFade: true)
            self?.signInWindowController = nil
        }
        signInWindowController?.start()
    }

    @objc func checkUsage(_ sender: NSMenuItem) {
        UsageAPIClient.resetCooldown()
        // Local tracker is always available — scans ~/.claude/projects/**/*.jsonl
        let local = LocalUsageTracker.estimate()
        let tokens5h = LocalUsageTracker.formatTokens(local.snapshot.fiveHourTokens)
        let tokens7d = LocalUsageTracker.formatTokens(local.snapshot.sevenDayTokens)

        UsageAPIClient.fetch { [weak self] usage in
            guard let cat = self?.controller?.cat else { return }
            if let usage {
                let didNotify = cat.checkThresholds(usage)
                if !didNotify {
                    let message = String(
                        format: """
                        **plunder report cap'n**
                        5h rations: **%.0f%%** spent · %@ tokens · %d turns
                        7d rations: **%.0f%%** spent · %@ tokens · %d turns
                        """,
                        usage.fiveHourPct, tokens5h, local.snapshot.fiveHourTurns,
                        usage.sevenDayPct, tokens7d, local.snapshot.sevenDayTurns
                    )
                    cat.showPreview(message, autoFade: true)
                }
            } else {
                // No claude session — show local estimate as fallback
                let message = String(
                    format: """
                    **local plunder** (no claude session)
                    5h: ~%d%% · %@ tokens · %d turns
                    7d: ~%d%% · %@ tokens · %d turns
                    sign in to claude for real rations
                    """,
                    local.fiveHourUsedPct, tokens5h, local.snapshot.fiveHourTurns,
                    local.sevenDayUsedPct, tokens7d, local.snapshot.sevenDayTurns
                )
                cat.showPreview(message, autoFade: true)
            }
        }
    }

    @objc func wakeUpCat(_ sender: NSMenuItem) {
        controller?.cat.wakeUp()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
