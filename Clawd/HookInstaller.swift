import Foundation

/// Installs Claude Code hooks into ~/.claude/settings.json so that real Claude Code
/// sessions send events to the cat's HookServer.
enum HookInstaller {
    private static let hookPort = HookServer.port
    private static let markerComment = "clawd-hook"

    private static let hookCommands: [String: String] = [
        // SessionStart fires when `claude` (or Claude Code session) boots. We launch
        // Shanks in the background here; `open -gb` is a no-op if it's already running.
        "SessionStart":      "open -gb com.shanks.app >/dev/null 2>&1 || true",
        "Notification":      "curl -sf --max-time 3 -X POST http://localhost:\(hookPort)/notification -H 'Content-Type: application/json' -d @- || true",
        "PermissionRequest": "curl -sf --max-time 3 -X POST http://localhost:\(hookPort)/permission-request -H 'Content-Type: application/json' -d @- || true",
        "PostToolUse":       "curl -sf --max-time 3 -X POST http://localhost:\(hookPort)/post-tool-use -H 'Content-Type: application/json' -d @- || true",
        "Stop":              "curl -sf --max-time 3 -X POST http://localhost:\(hookPort)/stop -H 'Content-Type: application/json' -d @- || true",
    ]

    static func install() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")

        var root: [String: Any] = (try? readJSON(at: settingsURL)) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        var changed = false
        for (event, command) in hookCommands {
            var existing = hooks[event] as? [[String: Any]] ?? []

            // Check if our exact command is already present
            let exactMatch = existing.contains { group in
                let cmds = group["hooks"] as? [[String: Any]] ?? []
                return cmds.contains { ($0["command"] as? String) == command }
            }
            if exactMatch { continue }

            // Remove any stale entry pointing at our port (old command without --max-time)
            existing = existing.filter { group in
                let cmds = group["hooks"] as? [[String: Any]] ?? []
                return !cmds.contains { ($0["command"] as? String)?.contains("localhost:\(hookPort)") == true }
            }

            let newEntry: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "command", "command": command]]
            ]
            hooks[event] = existing + [newEntry]
            changed = true
        }

        guard changed else { return }
        root["hooks"] = hooks

        do {
            try? FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            NSLog("[HookInstaller] Hooks installed in %@", settingsURL.path)
        } catch {
            NSLog("[HookInstaller] Failed to write settings.json: %@", error.localizedDescription)
        }
    }

    private static func readJSON(at url: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
