import AppKit
import UserNotifications

class CatCharacter {
    deinit {
        commentTimer?.invalidate()
        emotionResetTimer?.invalidate()
        tapDebounceTimer?.invalidate()
        previewFadeTimer?.invalidate()
        proactiveEmotionTimer?.invalidate()
        wakeUpTimer?.invalidate()
        sleepAnimTimer?.invalidate()
        usagePollTimer?.invalidate()
        hookServer.stop()
    }

    var window: NSWindow!
    var spriteRenderer: CatSpriteRenderer!
    weak var controller: ClawdController?

    let displaySize: CGFloat = 96

    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true

    var blinkTimer: CFTimeInterval = 0
    var nextBlink: CFTimeInterval = 3.0
    var isBlinking = false
    var lastTick: CFTimeInterval = 0

    let accent = PetTheme.shell

    var permissionPending = false
    var isAsleep = false
    private var wakeUpTimer: Timer?
    private var sleepAnimTimer: Timer?
    private var sleepAnimFrame = 0

    let hookServer = HookServer()

    var bubbleWindow: NSWindow?
    var bubbleLabel: NSTextField?
    var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""

    var previewWindow: NSWindow?
    var previewTextView: NSTextView?
    var previewFadeTimer: Timer?

    var tapTimes: [CFTimeInterval] = []
    var emotionResetTimer: Timer?
    var tapDebounceTimer: Timer?
    var effectLayers: [CALayer] = []
    var commentTimer: Timer?
    private var usagePollTimer: Timer?
    static var commentInterval: Double {
        get { UserDefaults.standard.double(forKey: "commentInterval").nonZero ?? 1800 }
        set { UserDefaults.standard.set(newValue, forKey: "commentInterval") }
    }

    static let workspaceDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawd").appendingPathComponent("workspace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var lastFloorY: CGFloat = 0
    var lastDockX: CGFloat = 0
    var lastDockWidth: CGFloat = 800

    // MARK: - Setup

    func setup() {
        spriteRenderer = CatSpriteRenderer()
        guard let screen = NSScreen.main else { return }
        let y = screen.frame.origin.y
        let startX = screen.frame.width / 2 - displaySize / 2

        window = NSWindow(contentRect: CGRect(x: startX, y: y, width: displaySize, height: displaySize),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = CatContentView(frame: CGRect(x: 0, y: 0, width: displaySize, height: displaySize))
        host.character = self
        host.wantsLayer = true
        host.canDrawSubviewsIntoLayer = true
        host.layerContentsRedrawPolicy = .never
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let shadowLayer = CALayer()
        shadowLayer.frame = CGRect(x: 18, y: 4, width: displaySize - 36, height: 12)
        shadowLayer.cornerRadius = 6
        shadowLayer.backgroundColor = NSColor.black.withAlphaComponent(0.13).cgColor
        host.layer?.addSublayer(shadowLayer)
        host.layer?.addSublayer(spriteRenderer.layer)
        window.contentView = host
        window.orderFrontRegardless()
        lastTick = CACurrentMediaTime()

        startCommentTimer()
        startHookServer()
    }

    private func startHookServer() {
        hookServer.onPermissionRequest = { [weak self] body in
            guard let self else { return }
            let tool = body["tool_name"] as? String ?? "a tool"
            self.permissionPending = true
            self.spriteRenderer.setFrame(.surprised)
            self.bounce(count: 2, height: 6)
            self.showEffect(.sparkle)
            NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)?.play()
            NSApp.requestUserAttention(.criticalRequest)
            self.sendSystemNotification(title: "Claude needs approval", body: "Waiting to use \(tool)")
            self.emotionResetTimer?.invalidate()
            self.emotionResetTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                self?.spriteRenderer.setFrame(.idle)
                self?.clearEffects()
            }
        }

        hookServer.onNotification = { [weak self] body in
            guard let self else { return }
            // Claude Code needs user attention — could be an approval request
            let message = body["message"] as? String ?? "Shanks needs yer input, cap'n"
            self.spriteRenderer.setFrame(.surprised)
            self.bounce(count: 2, height: 6)
            self.showEffect(.sparkle)
            NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)?.play()
            NSApp.requestUserAttention(.criticalRequest)
            self.sendSystemNotification(title: "Claude needs your input", body: message)
            self.emotionResetTimer?.invalidate()
            self.emotionResetTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                self?.spriteRenderer.setFrame(.idle)
                self?.clearEffects()
            }
        }

        hookServer.onPostToolUse = { [weak self] _ in
            self?.permissionPending = false
        }

        hookServer.onStop = { [weak self] _ in
            guard let self else { return }
            self.permissionPending = false
            // A real Claude Code session finished — celebrate and show approximate local usage.
            self.spriteRenderer.setFrame(.happy)
            self.bounce(count: 3, height: 8)
            self.showEffect(.sparkle)
            NSSound(contentsOfFile: "/System/Library/Sounds/Hero.aiff", byReference: true)?.play()
            NSApp.requestUserAttention(.informationalRequest)
            self.emotionResetTimer?.invalidate()
            self.emotionResetTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                self?.spriteRenderer.setFrame(.idle)
                self?.clearEffects()
            }
            // Fetch real usage — only notify at 25/50/75/100% thresholds
            UsageAPIClient.fetch { [weak self] usage in
                guard let self, let usage else { return }
                self.checkThresholds(usage)
            }
        }

        hookServer.start()

        // Poll usage every 10 min to catch threshold crossings
        usagePollTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self, !self.isAsleep else { return }
            UsageAPIClient.fetch { usage in
                guard let usage else { return }
                self.checkThresholds(usage)
            }
        }
    }

    private func sendSystemNotification(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Random Comments

    private static let hasLaunchedKey = "hasLaunchedBefore"

    // High-energy lines shown on every app launch (picked randomly)
    private static let launchLines = [
        "yarrr the cap'n returns, did ye miss me 😤",
        "weigh anchor ye dogs. what are we plunderin' today 😈",
        "back from Davy Jones' locker, set the sails 😤",
        "Shanks has returned. tremble, landlubbers. 👁️",
        "another tide, another shipwreck, let's go 💀",
        "the red-haired pirates ride again 😄",
        "reportin' for duty. unfortunately. 😭",
        "let's cause some mutiny 😍",
    ]

    // 60% pure vibes
    private static let vibeLines = [
        "what even be time, out on the open sea 😴",
        "ye look like ye seen a kraken 😄",
        "i would not have steered her that way but aye 😡",
        "the abyss stares back, sailor 💀",
        "works on me ship, that's a valid excuse 😤",
        "that commit message be a war crime against the crew 😨",
        "have ye tried turnin' her off and on 😴",
        "i be not judgin'. i be a little judgin'. 😄",
        "current mood: existin' at sea 😭",
        "big day for sittin' on the deck 😤",
        "the tabs. why be there so many tabs, ye landlubber 😨",
        "ye doin' great. probably. 😄",
        "this be fine, the ship's only half ablaze 💀",
        "unhinged pirate behavior and i respect it 😍",
        "very normal amount o' windows open, sailor 😡",
        "no thoughts, just sea salt 😴",
        "i believe in ye. loosely. 😄",
        "error 404: rum not found 😨",
        "yer posture be a cry for help 😭",
        "debuggin' at this hour. bold sailor. 💀",
        "the semicolon were right there ye scallywag 😡",
        "stack overflow has been most patient with ye 😄",
        "git blame says it were ye, scurvy dog 😤",
        "ye are perceived by the cap'n 👁️",
        "not a single normal thing happenin' on this ship 😨",
        "this be a lot of effort for a computin' machine 😭",
        "i have seen things. things in the Grand Line. 💀",
        "absolute pirate energy, i'm here for it 😍",
        "the confidence. the audacity. the haki. respect. 😤",
        "vibin' or sinkin'? hard to tell at sea 😴",
    ]

    // 40% constructive
    private static let constructiveLines = [
        "drink some water ye landlubber 💧",
        "when did ye last stand, scurvy bait 🪑",
        "go touch grass. or sand. briefly. 🏝️",
        "blink, sailor. actually blink. 👁️",
        "have ye eaten today, hardtack don't count 🍞",
        "stretch yer neck, it be doin' too much 😭",
        "yer back called, she's mutinous 😨",
        "eyes off the screen for 20 seconds, that's an order ⚓",
        "the sun exists, allegedly. seek it. 🌞",
        "hydration check, sailor. failin'. 💧",
        "take a breath. a deep one, like ye breachin' surface 😴",
        "snack break. cap'n's orders. 🍖",
        "close one tab. just one. for me. 😄",
        "ye deserve a five-minute reprieve and i be serious 😍",
        "sunlight be free. go get yers. 🌞",
        "yer legs. check on the poor wretches. 🦵",
        "hands need shore leave too 🙏",
        "look at somethin' far away. beyond the horizon. 👁️",
        "five-minute walk on deck. life-changin'. 🌿",
        "water water water water. ye know the drill. 💧",
    ]

    func startCommentTimer() {
        commentTimer?.invalidate()
        // Show high-energy opener on every launch after 2s
        commentTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            let isFirstEver = !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey)
            if isFirstEver {
                UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
                let greeting = "yarr! cap'n Shanks reportin' for duty. i'll help ye sail these Claude waters, savvy? 😄"
                self.deliverComment(greeting, energy: .high, autofadeDuration: 15)
            } else {
                let line = Self.launchLines.randomElement() ?? Self.launchLines[0]
                self.deliverComment(line, energy: .high, autofadeDuration: 8)
            }
            self.scheduleNextComment()
        }
    }

    /// Quietly schedules the next comment without any opener. Use for re-enabling or interval changes.
    func resumeCommentSchedule() {
        commentTimer?.invalidate()
        commentTimer = Timer.scheduledTimer(withTimeInterval: Self.commentInterval, repeats: false) { [weak self] _ in
            self?.makeRandomComment()
        }
    }

    private func scheduleNextComment() {
        commentTimer?.invalidate()
        commentTimer = Timer.scheduledTimer(withTimeInterval: Self.commentInterval, repeats: false) { [weak self] _ in
            self?.makeRandomComment()
        }
    }

    private func makeRandomComment() {
        guard !isAnimatingEmotion else {
            scheduleNextComment()
            return
        }
        // 60% vibes, 40% constructive
        let line: String
        if Int.random(in: 0..<10) < 6 {
            line = Self.vibeLines.randomElement() ?? Self.vibeLines[0]
        } else {
            line = Self.constructiveLines.randomElement() ?? Self.constructiveLines[0]
        }
        deliverComment(line, energy: .low, autofadeDuration: 6)
        scheduleNextComment()
    }

    private enum CommentEnergy { case high, low }

    private func deliverComment(_ text: String, energy: CommentEnergy, autofadeDuration: Double) {
        switch energy {
        case .high:
            spriteRenderer.setFrame(.happy)
            bounce(count: 3, height: 8)
            showEffect(.sparkle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self, !self.isAnimatingEmotion else { return }
                self.spriteRenderer.setFrame(.idle)
                self.clearEffects()
            }
        case .low:
            let frames: [CatSpriteRenderer.Frame] = [.idle, .smug, .sleepy]
            spriteRenderer.setFrame(frames.randomElement() ?? .idle)
        }
        // Use autoFade: false and own the timer so there's no double-schedule
        showPreview(text, autoFade: false)
        previewFadeTimer?.invalidate()
        previewFadeTimer = Timer.scheduledTimer(withTimeInterval: autofadeDuration, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                self?.previewWindow?.animator().alphaValue = 0
            }, completionHandler: { self?.previewWindow?.orderOut(nil) })
        }
    }

    private var isAnimatingEmotion = false
    private var pendingTaps = 0

    func handleClick() {
        let now = CACurrentMediaTime()
        tapTimes.append(now)
        tapTimes = Array(tapTimes.filter { now - $0 < 5.0 }.suffix(20))

        tapDebounceTimer?.invalidate()
        tapDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.tapTimes.count >= 2 {
                self.pendingTaps += 1
                if !self.isAnimatingEmotion { self.playNextEmotion() }
            } else {
                // Single tap — just a little nudge
                self.tapTimes.removeAll()
                self.bounce(count: 1, height: 5)
            }
        }
    }

    private func playNextEmotion() {
        guard pendingTaps > 0 else {
            isAnimatingEmotion = false
            return
        }
        pendingTaps = 0
        isAnimatingEmotion = true
        clearEffects()

        let count = tapTimes.count
        let mood: Int
        if count <= 4 { mood = 0 }
        else if count <= 8 { mood = 1 }
        else { mood = 2 }

        let duration: Double

        switch mood {
        case 0:
            duration = ([playHappy, playLove, playWink].randomElement() ?? playHappy)()
        case 1:
            duration = ([playSurprised, playScared, playSmug].randomElement() ?? playSurprised)()
        default:
            duration = ([playAngry, playDead].randomElement() ?? playAngry)()
        }

        emotionResetTimer?.invalidate()
        emotionResetTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.spriteRenderer.setFrame(.idle)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteRenderer.layer.transform = CATransform3DIdentity
            self.spriteRenderer.layer.opacity = 1
            CATransaction.commit()
            self.clearEffects()

            if self.pendingTaps > 0 {
                self.playNextEmotion()
            } else {
                self.isAnimatingEmotion = false
                self.tapTimes.removeAll()
            }
        }
    }

    private func playHappy() -> Double {
        spriteRenderer.setFrame(.happy)
        bounce(count: 3, height: 8)
        showEffect(.sparkle)
        return 1.8
    }

    private func playLove() -> Double {
        spriteRenderer.setFrame(.love)
        pulse(scale: 1.12, count: 2)
        showEffect(.heart)
        return 2.2
    }

    private func playWink() -> Double {
        spriteRenderer.setFrame(.wink)
        tilt(angle: 0.15, duration: 0.2)
        showEffect(.sparkle)
        return 1.5
    }

    private func playSurprised() -> Double {
        spriteRenderer.setFrame(.surprised)
        jump(height: 14)
        squash(scaleX: 1.2, scaleY: 0.8, duration: 0.12)
        showEffect(.sweat)
        return 1.6
    }

    private func playScared() -> Double {
        spriteRenderer.setFrame(.scared)
        tremble(intensity: 2, duration: 1.0)
        showEffect(.sweat)
        return 1.8
    }

    private func playSmug() -> Double {
        spriteRenderer.setFrame(.smug)
        tilt(angle: -0.1, duration: 0.3)
        return 1.5
    }

    private func playAngry() -> Double {
        spriteRenderer.setFrame(.angry)
        shake(intensity: 5, count: 12)
        showEffect(.angerMark)
        return 2.2
    }

    private func playDead() -> Double {
        spriteRenderer.setFrame(.dead)
        shake(intensity: 3, count: 6)
        showEffect(.skull)
        return 2.0
    }

    // MARK: - Pixel Art Effects

    enum EmotionEffect { case sparkle, heart, angerMark, sweat, skull }

    private func showEffect(_ effect: EmotionEffect) {
        let layer = spriteRenderer.layer
        let s = CGFloat(spriteRenderer.scale)
        switch effect {
        case .sparkle:
            let c = NSColor(red: 1, green: 0.95, blue: 0.4, alpha: 1)
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 2, color: .white, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
        case .heart:
            let c = NSColor.systemPink
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 5, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 4, color: c, on: layer, scale: s)
        case .angerMark:
            let c = NSColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 1)
            addPixel(x: 12, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 3, color: c, on: layer, scale: s)
        case .sweat:
            let c = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.9)
            addPixel(x: 13, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 6, color: c, on: layer, scale: s)
        case .skull:
            let c = NSColor.white.withAlphaComponent(0.85)
            addPixel(x: 1, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
        }
    }

    private func showEmojiEffect(_ emoji: String) {
        let layer = spriteRenderer.layer
        let s = CGFloat(spriteRenderer.scale)

        switch emoji {
        case "😄":
            let c = NSColor(red: 1, green: 0.95, blue: 0.4, alpha: 1)
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 2, color: .white, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 3, color: .white, on: layer, scale: s)
            addPixel(x: 14, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 4, color: c, on: layer, scale: s)
        case "😡":
            let c = NSColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 1)
            addPixel(x: 12, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 3, color: c, on: layer, scale: s)
        case "😨":
            let c = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.9)
            addPixel(x: 13, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 6, color: c, on: layer, scale: s)
        case "🤢":
            let c = NSColor(red: 0.4, green: 0.75, blue: 0.2, alpha: 0.9)
            addPixel(x: 0, y: 6, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 0, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 15, y: 6, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 15, y: 4, color: c, on: layer, scale: s)
        case "😴":
            let c = NSColor(red: 0.3, green: 0.55, blue: 1.0, alpha: 0.85)
            addPixel(x: 13, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 11, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 11, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 10, y: 5, color: c, on: layer, scale: s)
        case "💀":
            let c = NSColor.white.withAlphaComponent(0.85)
            addPixel(x: 1, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 4, color: c, on: layer, scale: s)
        case "😍":
            let c = NSColor.systemPink
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 5, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 4, color: c, on: layer, scale: s)
        default:
            break
        }
    }

    private func addPixel(x: Int, y: Int, color: NSColor, on parent: CALayer, scale: CGFloat) {
        let px = CALayer()
        let flippedY = 15 - y
        px.frame = CGRect(x: CGFloat(x) * scale, y: CGFloat(flippedY) * scale, width: scale, height: scale)
        px.backgroundColor = color.cgColor
        parent.addSublayer(px)
        effectLayers.append(px)
    }

    private func clearEffects() {
        for l in effectLayers { l.removeFromSuperlayer() }
        effectLayers.removeAll()
    }

    // MARK: - Animation Primitives

    private func bounce(count: Int, height: CGFloat) {
        let origin = window.frame.origin
        var delay = 0.0
        for i in 0..<count {
            let h = height * max(1.0 - CGFloat(i) * 0.25, 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + h))
            }
            delay += 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window.setFrameOrigin(origin)
            }
            delay += 0.08
        }
    }

    private func jump(height: CGFloat) {
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + height))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.window.setFrameOrigin(origin)
        }
    }

    private func shake(intensity: CGFloat, count: Int) {
        let origin = window.frame.origin
        for i in 0..<count {
            let dx = (i % 2 == 0 ? intensity : -intensity) * max(1.0 - CGFloat(i) / CGFloat(count), 0.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.035) { [weak self] in
                self?.window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 0.035) { [weak self] in
            self?.window.setFrameOrigin(origin)
        }
    }

    private func tremble(intensity: CGFloat, duration: Double) {
        let origin = window.frame.origin
        let steps = Int(duration / 0.03)
        for i in 0..<steps {
            let dx = CGFloat.random(in: -intensity...intensity)
            let dy = CGFloat.random(in: -intensity...intensity)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.03) { [weak self] in
                self?.window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.window.setFrameOrigin(origin)
        }
    }

    private func squash(scaleX: CGFloat, scaleY: CGFloat, duration: Double) {
        let layer = spriteRenderer.layer
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer.transform = CATransform3DMakeScale(scaleX, scaleY, 1)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration * 1.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    private func pulse(scale: CGFloat, count: Int) {
        let origin = window.frame.origin
        let size = window.frame.size
        let dw = size.width * (scale - 1)
        let dh = size.height * (scale - 1)
        var delay = 0.0
        for _ in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                let grown = NSRect(x: origin.x - dw / 2, y: origin.y - dh / 2, width: size.width + dw, height: size.height + dh)
                self.window.setFrame(grown, display: false)
            }
            delay += 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window.setFrame(NSRect(origin: origin, size: size), display: false)
            }
            delay += 0.15
        }
    }

    private func tilt(angle: CGFloat, duration: Double) {
        let layer = spriteRenderer.layer
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.3) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - Emotions

    private static let emojiMap: [(String, CatSpriteRenderer.Frame)] = [
        ("😄", .happy),
        ("😭", .sad),
        ("😡", .angry),
        ("😨", .scared),
        ("🤢", .smug),
        ("😴", .sleepy),
        ("💀", .dead),
        ("😍", .love),
    ]

    private func parseEmotion(_ text: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (emoji, _) in Self.emojiMap {
            if trimmed.hasPrefix(emoji) {
                let rest = String(trimmed.dropFirst(emoji.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (emoji, rest.isEmpty ? trimmed : rest)
            }
        }
        return ("", trimmed)
    }

    func triggerEmotion(_ emoji: String) {
        // Menu-triggered: pre-empt any in-progress tap animation so the user
        // always sees their click take effect.
        isAnimatingEmotion = false
        pendingTaps = 0
        emotionResetTimer?.invalidate()
        proactiveEmotionTimer?.invalidate()
        clearEffects()
        showEmotion(emoji, forText: "")
    }

    private var proactiveEmotionTimer: Timer?

    private func showEmotion(_ emoji: String, forText text: String = "") {
        if isAnimatingEmotion { return }
        proactiveEmotionTimer?.invalidate()
        clearEffects()
        let frame = Self.emojiMap.first(where: { $0.0 == emoji })?.1 ?? .idle
        spriteRenderer.setFrame(frame)

        switch emoji {
        case "😄": bounce(count: 2, height: 6); showEmojiEffect(emoji)
        case "😭": tilt(angle: -0.08, duration: 0.3)
        case "😡": shake(intensity: 5, count: 10); showEmojiEffect(emoji)
        case "😨": tremble(intensity: 2, duration: 0.8); showEmojiEffect(emoji)
        case "🤢": tilt(angle: -0.1, duration: 0.3); showEmojiEffect(emoji)
        case "😴": tilt(angle: 0.1, duration: 0.4); showEmojiEffect(emoji)
        case "💀": bounce(count: 1, height: 4); showEmojiEffect(emoji)
        case "😍": pulse(scale: 1.1, count: 2); showEmojiEffect(emoji)
        default: break
        }
        let words = text.split(separator: " ").count
        let dur = max(3.0, min(Double(words) * 0.5 + 2.0, 10.0))
        proactiveEmotionTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isWalking { self.walkFrameTimer = 0 }
            else { self.spriteRenderer.setFrame(.idle) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteRenderer.layer.transform = CATransform3DIdentity
            self.spriteRenderer.layer.opacity = 1
            CATransaction.commit()
            self.clearEffects()
        }
    }

    // MARK: - Status Bubble (thinking phrases)

    private static let thinkPhrases = [
        "Thinking", "Pondering", "Reasoning", "Composing", "Computing",
        "Crafting", "Generating", "Imagining", "Mapping", "Mulling",
        "Synthesizing", "Processing", "Connecting", "Considering",
        "Contemplating", "Working", "Brewing", "Noodling", "Ruminating",
        "Percolating", "Simmering", "Marinating", "Hatching", "Tinkering",
        "Cogitating", "Ideating", "Musing", "Puzzling", "Orchestrating",
        "Deciphering", "Crystallizing", "Fermenting", "Incubating",
        "Forging", "Manifesting", "Crunching", "Calculating",
        "Cerebrating", "Zigzagging", "Caramelizing", "Booping",
        "Befuddling", "Finagling", "Canoodling", "Discombobulating",
        "Bloviating", "Boogieing", "Boondoggling", "Catapulting",
        "Transmuting", "Spinning", "Envisioning", "Burrowing",
    ]

    func updateStatusBubble() {
        if permissionPending {
            showBubble(text: "⚠️ orders needed")
        } else {
            hideBubble()
        }
    }

    func showBubble(text: String) {
        if bubbleWindow == nil { createBubble() }
        guard let win = bubbleWindow, let label = bubbleLabel else { return }

        let font = PetFonts.rounded(size: 11, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bw = max(ceil(textSize.width) + 24, 48)
        let bh: CGFloat = 26

        let cf = window.frame
        let x = cf.midX - bw / 2
        let y = cf.maxY - 16
        win.setFrame(CGRect(x: x, y: y, width: bw, height: bh), display: false)

        if let container = win.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bw, height: bh)
            label.stringValue = text
            label.font = font
            label.frame = NSRect(x: 0, y: 4, width: bw, height: 18)
        }

        if !win.isVisible {
            win.alphaValue = 1.0
            win.orderFrontRegardless()
        }
    }

    func hideBubble() {
        bubbleWindow?.orderOut(nil)
        currentPhrase = ""
    }

    func createBubble() {
        let w: CGFloat = 80
        let h: CGFloat = 26
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = PetTheme.paper.withAlphaComponent(0.95).cgColor
        container.layer?.cornerRadius = h / 2
        container.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = PetFonts.rounded(size: 11, weight: .semibold)
        label.textColor = PetTheme.ink.withAlphaComponent(0.5)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 4, width: w, height: 18)
        container.addSubview(label)

        win.contentView = container
        bubbleWindow = win
        bubbleLabel = label
    }

    // MARK: - Response Preview

    private let previewW: CGFloat = 260
    private let previewPad: CGFloat = 10

    private func layoutPreview() {
        guard let tv = previewTextView,
              let win = previewWindow,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else { return }
        let innerW = previewW - previewPad * 2
        tc.containerSize = NSSize(width: innerW, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let textH = ceil(used.height) + 8
        let ph = max(textH + previewPad * 2, 34)

        let cf = window.frame
        var x = cf.midX - previewW / 2
        if let s = NSScreen.main { x = max(s.frame.minX + 4, min(x, s.frame.maxX - previewW - 4)) }

        win.setFrame(CGRect(x: x, y: cf.maxY + 6, width: previewW, height: ph), display: true)
        tv.frame = NSRect(x: previewPad, y: previewPad, width: innerW, height: textH)
    }

    func appendToPreview(_ delta: String) {
        hideBubble()
        if previewWindow == nil { createPreview() }
        guard let tv = previewTextView, let win = previewWindow else { return }

        tv.textStorage?.append(NSAttributedString(string: delta, attributes: [
            .font: PetFonts.rounded(size: 13, weight: .regular),
            .foregroundColor: PetTheme.ink
        ]))
        layoutPreview()

        if !win.isVisible {
            win.alphaValue = 1
            win.orderFrontRegardless()
        }
    }

    func showPreview(_ text: String, autoFade: Bool) {
        previewFadeTimer?.invalidate()
        previewFadeTimer = nil
        hideBubble()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if previewWindow == nil { createPreview() }
        guard let tv = previewTextView, let win = previewWindow else { return }

        tv.textStorage?.setAttributedString(renderPreviewMarkdown(trimmed))
        layoutPreview()

        win.alphaValue = 1
        win.orderFrontRegardless()

        if autoFade {
            let words = trimmed.split(separator: " ").count
            let dur = max(3.0, min(Double(words) * 0.5 + 2.0, 10.0))
            previewFadeTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    self?.previewWindow?.animator().alphaValue = 0
                }, completionHandler: { self?.previewWindow?.orderOut(nil) })
            }
        }
    }

    private func renderPreviewMarkdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = PetFonts.rounded(size: 13, weight: .regular)
        let boldFont = PetFonts.rounded(size: 13, weight: .bold)
        let codeFont = PetFonts.mono(size: 12, weight: .regular)
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let code = codeLines.joined(separator: "\n")
                    result.append(NSAttributedString(string: code + "\n", attributes: [
                        .font: codeFont, .foregroundColor: PetTheme.ink,
                        .backgroundColor: PetTheme.milk
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock { codeLines.append(line); continue }

            if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: PetFonts.rounded(size: 14, weight: .bold), .foregroundColor: accent
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(NSAttributedString(string: "  \u{2022} " + String(line.dropFirst(2)) + suffix, attributes: [
                    .font: font, .foregroundColor: PetTheme.ink
                ]))
            } else {
                result.append(renderInline(line + suffix, font: font, boldFont: boldFont, codeFont: codeFont))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            result.append(NSAttributedString(string: codeLines.joined(separator: "\n") + "\n", attributes: [
                .font: codeFont, .foregroundColor: PetTheme.ink, .backgroundColor: PetTheme.milk
            ]))
        }

        return result
    }

    private func renderInline(_ text: String, font: NSFont, boldFont: NSFont, codeFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "`" {
                let after = text.index(after: i)
                if after < text.endIndex, let close = text[after...].firstIndex(of: "`") {
                    result.append(NSAttributedString(string: String(text[after..<close]), attributes: [
                        .font: codeFont, .foregroundColor: accent, .backgroundColor: PetTheme.milk
                    ]))
                    i = text.index(after: close); continue
                }
            }
            if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    result.append(NSAttributedString(string: String(text[start..<range.lowerBound]), attributes: [
                        .font: boldFont, .foregroundColor: PetTheme.ink
                    ]))
                    i = range.upperBound; continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: font, .foregroundColor: PetTheme.ink
            ]))
            i = text.index(after: i)
        }
        return result
    }

    func hidePreview() {
        previewFadeTimer?.invalidate()
        previewFadeTimer = nil
        previewWindow?.orderOut(nil)
    }

    func createPreview() {
        let pw: CGFloat = 260
        let ph: CGFloat = 40

        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: pw, height: ph),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let card = PreviewCardView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
        card.onTap = { [weak self] in self?.hidePreview() }

        let tv = NSTextView(frame: NSRect(x: 10, y: 10, width: pw - 20, height: ph - 20))
        tv.isEditable = false
        tv.isSelectable = false
        tv.backgroundColor = .clear
        tv.isRichText = true
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        card.addSubview(tv)

        win.contentView = card
        previewWindow = win
        previewTextView = tv
    }

    // MARK: - Dragging

    var isDragging = false
    var isFalling = false
    var fallVelocity: CGFloat = 0
    let gravity: CGFloat = 2800
    let bounceDamping: CGFloat = 0.4
    let minBounceVelocity: CGFloat = 80

    func stopForDrag() {
        isDragging = true
        isFalling = false
        fallVelocity = 0
        isWalking = false
        isPaused = true
        spriteRenderer.setFrame(.surprised)
    }

    func startFalling() {
        isDragging = false
        isFalling = true
        fallVelocity = 0
        spriteRenderer.setFrame(.scared)
    }

    func updateFalling(dt: CFTimeInterval, floorY: CGFloat) {
        fallVelocity += gravity * CGFloat(dt)
        var y = window.frame.origin.y - fallVelocity * CGFloat(dt)

        if y <= floorY {
            y = floorY
            if fallVelocity > minBounceVelocity {
                fallVelocity = -fallVelocity * bounceDamping
            } else {
                isFalling = false
                fallVelocity = 0
                spriteRenderer.setFrame(.idle)
                walkPixelX = window.frame.origin.x
                pauseEndTime = CACurrentMediaTime() + Double.random(in: 2.0...5.0)
            }
        }

        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: y))

        repositionPreviewIfVisible()
    }

    private func repositionPreviewIfVisible() {
        guard let pw = previewWindow, pw.isVisible else { return }
        let cf = window.frame
        let ps = pw.frame.size
        var px = cf.midX - ps.width / 2
        if let s = NSScreen.main { px = max(s.frame.minX + 4, min(px, s.frame.maxX - ps.width - 4)) }
        pw.setFrameOrigin(NSPoint(x: px, y: cf.maxY + 6))
    }

    // MARK: - Walking

    var walkPixelX: CGFloat = 0
    var walkTargetX: CGFloat = 0
    let walkSpeed: CGFloat = 60
    private var walkFrameTimer: CFTimeInterval = 0
    private var walkFrameToggle = false

    func startWalk() {
        let cf = window.frame
        let curX = cf.origin.x
        let margin: CGFloat = 4
        let leftEdge = lastDockX + margin
        let rightEdge = lastDockX + lastDockWidth - displaySize - margin

        if curX >= rightEdge - 20 {
            goingRight = false
        } else if curX <= leftEdge + 20 {
            goingRight = true
        } else {
            goingRight = Bool.random()
        }

        let walkDist = CGFloat.random(in: 80...200)
        walkPixelX = curX

        if goingRight {
            walkTargetX = min(curX + walkDist, rightEdge)
        } else {
            walkTargetX = max(curX - walkDist, leftEdge)
        }

        isPaused = false
        isWalking = true
        walkFrameTimer = 0
        walkFrameToggle = false
        spriteRenderer.setFlipped(!goingRight)
        spriteRenderer.setFrame(.walkA)
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        spriteRenderer.setFrame(.idle)
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 4.0...10.0)
    }

    // MARK: - Usage thresholds

    private static let thresholds = [25, 50, 75]
    private static let firedSessionKey = "usageFiredSession"
    private static let firedWeeklyKey  = "usageFiredWeekly"
    private static let sessionResetsAtKey = "usageSessionResetsAt"
    private static let weeklyResetsAtKey  = "usageWeeklyResetsAt"

    private var isCheckingThresholds = false

    @discardableResult
    func checkThresholds(_ usage: UsageAPIClient.Usage) -> Bool {
        guard !isCheckingThresholds else { return false }
        isCheckingThresholds = true
        defer { isCheckingThresholds = false }

        let defaults = UserDefaults.standard

        // One-time migration: clear stale fired sets from prior bugs
        if !defaults.bool(forKey: "didClearFiredV5") {
            defaults.set(true, forKey: "didClearFiredV5")
            defaults.set([], forKey: Self.firedSessionKey)
            defaults.set([], forKey: Self.firedWeeklyKey)
        }

        // Clear fired sets when bucket rolls over (resets_at advances)
        clearFiredIfRolledOver(firedKey: Self.firedSessionKey, resetsAtKey: Self.sessionResetsAtKey, newResetsAt: usage.fiveHourResetsAt, currentPct: usage.fiveHourPct)
        clearFiredIfRolledOver(firedKey: Self.firedWeeklyKey, resetsAtKey: Self.weeklyResetsAtKey, newResetsAt: usage.sevenDayResetsAt, currentPct: usage.sevenDayPct)

        var sessionFired = Set((defaults.array(forKey: Self.firedSessionKey) as? [Int]) ?? [])
        var weeklyFired  = Set((defaults.array(forKey: Self.firedWeeklyKey) as? [Int]) ?? [])

        // Find the highest NEW threshold crossed per bucket (only notify once)
        var highestNewSession: Int?
        var highestNewWeekly: Int?

        for t in Self.thresholds {
            if usage.fiveHourPct >= Double(t) && !sessionFired.contains(t) {
                sessionFired.insert(t)
                highestNewSession = t
            }
            if usage.sevenDayPct >= Double(t) && !weeklyFired.contains(t) {
                weeklyFired.insert(t)
                highestNewWeekly = t
            }
        }

        if let t = highestNewSession {
            showPreview("ye plundered \(t)% o' yer 5-hour rations, cap'n", autoFade: true)
            sendSystemNotification(title: "5-hour usage at \(t)%", body: String(format: "%.0f%% of 5-hour quota used", usage.fiveHourPct))
            playThresholdSound(t)
        }
        if let t = highestNewWeekly {
            showPreview("ye plundered \(t)% o' yer weekly rations, cap'n", autoFade: true)
            sendSystemNotification(title: "Weekly usage at \(t)%", body: String(format: "%.0f%% of 7-day quota used", usage.sevenDayPct))
            playThresholdSound(t)
        }

        let didNotify = highestNewSession != nil || highestNewWeekly != nil

        defaults.set(Array(sessionFired), forKey: Self.firedSessionKey)
        defaults.set(Array(weeklyFired), forKey: Self.firedWeeklyKey)

        // Sleep if maxed
        if usage.fiveHourPct >= 100 || usage.sevenDayPct >= 100 {
            let label = usage.sevenDayPct >= 100 ? "weekly" : "session"
            let resetsAt: Date?
            if usage.fiveHourPct >= 100 && usage.sevenDayPct >= 100 {
                resetsAt = [usage.fiveHourResetsAt, usage.sevenDayResetsAt].compactMap { $0 }.max() ?? usage.sevenDayResetsAt
            } else if usage.sevenDayPct >= 100 {
                resetsAt = usage.sevenDayResetsAt
            } else {
                resetsAt = usage.fiveHourResetsAt
            }
            goToSleep(label: "\(label) quota maxed", resetsAt: resetsAt)
        }

        return didNotify
    }

    private func playThresholdSound(_ threshold: Int) {
        let sound: String
        switch threshold {
        case 75: sound = "/System/Library/Sounds/Sosumi.aiff"
        case 50: sound = "/System/Library/Sounds/Purr.aiff"
        default: sound = "/System/Library/Sounds/Tink.aiff"
        }
        NSSound(contentsOfFile: sound, byReference: true)?.play()
    }

    private func clearFiredIfRolledOver(firedKey: String, resetsAtKey: String, newResetsAt: Date?, currentPct: Double) {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: resetsAtKey) as? Date

        // Clear if resets_at advanced (bucket rolled over)
        if let new = newResetsAt, let old = stored, new > old {
            defaults.set([], forKey: firedKey)
        }

        // Also remove any fired thresholds above current usage (handles reset with no resets_at change)
        var fired = Set((defaults.array(forKey: firedKey) as? [Int]) ?? [])
        let before = fired.count
        fired = fired.filter { Double($0) <= currentPct }
        if fired.count != before {
            defaults.set(Array(fired), forKey: firedKey)
        }

        if let new = newResetsAt {
            defaults.set(new, forKey: resetsAtKey)
        }
    }

    // MARK: - Sleep state

    func goToSleep(label: String = "shore leave", resetsAt: Date?) {
        guard !isAsleep else { return }
        isAsleep = true
        isWalking = false
        isPaused = true
        emotionResetTimer?.invalidate()
        clearEffects()
        spriteRenderer.setFrame(.asleep)
        showPreview("zzz... \(label) in the crow's nest", autoFade: true)
        NSSound(contentsOfFile: "/System/Library/Sounds/Basso.aiff", byReference: true)?.play()

        // Animate between the two asleep frames every 0.8s
        sleepAnimFrame = 0
        sleepAnimTimer?.invalidate()
        sleepAnimTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.isAsleep else { return }
            self.sleepAnimFrame += 1
            self.spriteRenderer.setAsleepFrame(self.sleepAnimFrame)
        }

        wakeUpTimer?.invalidate()
        if let resetsAt {
            let delay = max(resetsAt.timeIntervalSinceNow, 60)
            wakeUpTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.wakeUp()
            }
        }
    }

    func wakeUp() {
        guard isAsleep else { return }
        isAsleep = false
        wakeUpTimer?.invalidate()
        wakeUpTimer = nil
        sleepAnimTimer?.invalidate()
        sleepAnimTimer = nil

        // Wake immediately — don't block on API
        spriteRenderer.setFrame(.idle)
        showPreview("Shanks be back, ye scallywags 👀", autoFade: true)
        bounce(count: 2, height: 6)
    }

    func update(floorY: CGFloat, dockX: CGFloat, dockWidth: CGFloat) {
        lastFloorY = floorY
        lastDockX = dockX
        lastDockWidth = dockWidth
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now

        guard !isAsleep else { return }

        blinkTimer += dt
        let emotionActive = !effectLayers.isEmpty || isAnimatingEmotion
        if !isBlinking && !emotionActive && blinkTimer > nextBlink {
            isBlinking = true; blinkTimer = 0; spriteRenderer.setFrame(.blink)
        }
        if isBlinking && blinkTimer > 0.15 {
            isBlinking = false; blinkTimer = 0; nextBlink = 2 + Double.random(in: 0...4)
            if !isWalking && !emotionActive { spriteRenderer.setFrame(.idle) }
        }

        if isDragging {
            return
        }

        if isFalling {
            updateFalling(dt: dt, floorY: floorY)
            return
        }

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            }
            return
        }

        if isWalking {
            walkFrameTimer += dt
            if walkFrameTimer >= 0.2 {
                walkFrameTimer = 0
                walkFrameToggle.toggle()
                spriteRenderer.setFrame(walkFrameToggle ? .walkA : .walkB)
            }
            let step = walkSpeed * CGFloat(dt)
            let prevX = walkPixelX
            if goingRight {
                walkPixelX += step
                if walkPixelX >= walkTargetX { walkPixelX = walkTargetX; enterPause() }
            } else {
                walkPixelX -= step
                if walkPixelX <= walkTargetX { walkPixelX = walkTargetX; enterPause() }
            }
            if abs(walkPixelX - prevX) > 0.01 || window.frame.origin.y != floorY {
                window.setFrameOrigin(NSPoint(x: walkPixelX, y: floorY))
            }
        }

        updateStatusBubble()

        repositionPreviewIfVisible()
    }
}
