import Foundation

/// Installs a tiny always-on background watchdog (a launchd LaunchAgent) that ties
/// Shanks's lifecycle to Claude:
///   - launches Shanks when Claude Desktop OR the Claude Code CLI is running
///   - quits Shanks when BOTH are gone
///
/// Why a separate process? To LAUNCH Shanks the moment Claude Desktop opens, something
/// must be watching even while Shanks is NOT running. Shanks itself can't do that (it's
/// not running). So a minimal launchd agent polls every few seconds. It's extremely light
/// (a shell `sleep` loop with a couple of `pgrep`s).
enum WatchdogInstaller {
    static let label = "com.shanks.watchdog"
    private static let pollSeconds = 3

    private static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shanks", isDirectory: true)
    }
    private static var scriptURL: URL { supportDir.appendingPathComponent("watchdog.sh") }
    private static var logURL: URL { supportDir.appendingPathComponent("watchdog.log") }
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The watchdog shell script. Self-contained; reads nothing from the app bundle so it
    /// keeps working even if Shanks.app moves.
    private static var scriptBody: String {
        """
        #!/bin/bash
        # Shanks watchdog — launches/quits Shanks based on whether Claude is running.
        # Managed by launchd (\(label)). Auto-generated; edits will be overwritten.
        BUNDLE="com.shanks.app"

        claude_active() {
          # Claude Desktop app (any of its processes live under /Applications/Claude.app/)
          pgrep -f "/Applications/Claude.app/" >/dev/null 2>&1 && return 0
          # Claude Code CLI (process path contains claude-code/)
          pgrep -f "claude-code/" >/dev/null 2>&1 && return 0
          return 1
        }

        shanks_running() {
          pgrep -f "Shanks.app/Contents/MacOS/Clawd" >/dev/null 2>&1
        }

        log() { echo "$(date '+%H:%M:%S') $1" >> "$HOME/Library/Application Support/Shanks/watchdog.log"; }

        log "watchdog started (pid $$)"
        while true; do
          if claude_active; then
            if ! shanks_running; then
              log "claude active, shanks down -> launching"
              open -g -b "$BUNDLE" 2>>"$HOME/Library/Application Support/Shanks/watchdog.log" \\
                || open -g "/Applications/Shanks.app" 2>>"$HOME/Library/Application Support/Shanks/watchdog.log" \\
                || log "launch FAILED"
            fi
          else
            if shanks_running; then
              log "claude gone -> quitting shanks"
              osascript -e "tell application id \\"$BUNDLE\\" to quit" >/dev/null 2>&1 || true
            fi
          fi
          sleep \(pollSeconds)
        done
        """
    }

    private static func plistBody() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(scriptURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logURL.path)</string>
            <key>StandardErrorPath</key>
            <string>\(logURL.path)</string>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
        </dict>
        </plist>
        """
    }

    static func install() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Write script (overwrite if changed) and make it executable.
            let existingScript = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
            let scriptChanged = existingScript != scriptBody
            if scriptChanged {
                try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            }

            // Write plist (overwrite if changed).
            let existingPlist = (try? String(contentsOf: plistURL, encoding: .utf8)) ?? ""
            let plistChanged = existingPlist != plistBody()
            if plistChanged {
                try plistBody().write(to: plistURL, atomically: true, encoding: .utf8)
            }

            // (Re)load into launchd so it starts now and at every login.
            if scriptChanged || plistChanged || !isLoaded() {
                bootstrap()
            }
            NSLog("[WatchdogInstaller] watchdog ready (script changed: %@, plist changed: %@)",
                  scriptChanged ? "yes" : "no", plistChanged ? "yes" : "no")
        } catch {
            NSLog("[WatchdogInstaller] install failed: %@", error.localizedDescription)
        }
    }

    private static func isLoaded() -> Bool {
        let uid = getuid()
        return run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]) == 0
    }

    private static func bootstrap() {
        let uid = getuid()
        // bootout first (ignore failure if not loaded), then bootstrap fresh.
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        _ = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        _ = run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }

    /// Tear everything down (for an uninstall path). Not wired to UI yet.
    static func uninstall() {
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: scriptURL)
    }
}
