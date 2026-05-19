import Foundation

struct LocalUsageSnapshot {
    let fiveHourTokens: Int
    let sevenDayTokens: Int
    let fiveHourTurns: Int
    let sevenDayTurns: Int
}

struct LocalUsageBudget {
    let fiveHourTokens: Int
    let sevenDayTokens: Int

    static let `default` = LocalUsageBudget(
        fiveHourTokens: 20_000_000,
        sevenDayTokens: 140_000_000
    )
}

struct LocalUsageEstimate {
    let snapshot: LocalUsageSnapshot
    let budget: LocalUsageBudget

    var fiveHourUsedPct: Int {
        percentUsed(tokens: snapshot.fiveHourTokens, budget: budget.fiveHourTokens)
    }

    var sevenDayUsedPct: Int {
        percentUsed(tokens: snapshot.sevenDayTokens, budget: budget.sevenDayTokens)
    }

    var fiveHourLeftPct: Int { max(0, 100 - fiveHourUsedPct) }
    var sevenDayLeftPct: Int { max(0, 100 - sevenDayUsedPct) }

    private func percentUsed(tokens: Int, budget: Int) -> Int {
        guard budget > 0 else { return 0 }
        return min(999, Int((Double(tokens) / Double(budget) * 100).rounded()))
    }
}

enum LocalUsageTracker {
    private struct TurnUsage {
        let timestamp: Date
        let totalTokens: Int
    }

    private static let iso8601Parsers: [ISO8601DateFormatter] = {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractions, plain]
    }()

    static func snapshot(now: Date = Date()) -> LocalUsageSnapshot {
        let fiveHourCutoff = now.addingTimeInterval(-5 * 60 * 60)
        let sevenDayCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)

        var fiveHourTokens = 0
        var sevenDayTokens = 0
        var fiveHourTurns = 0
        var sevenDayTurns = 0

        for usage in loadTurnUsage() {
            if usage.timestamp >= fiveHourCutoff {
                fiveHourTokens += usage.totalTokens
                fiveHourTurns += 1
            }
            if usage.timestamp >= sevenDayCutoff {
                sevenDayTokens += usage.totalTokens
                sevenDayTurns += 1
            }
        }

        return LocalUsageSnapshot(
            fiveHourTokens: fiveHourTokens,
            sevenDayTokens: sevenDayTokens,
            fiveHourTurns: fiveHourTurns,
            sevenDayTurns: sevenDayTurns
        )
    }

    static func estimate(now: Date = Date(), budget: LocalUsageBudget = .default) -> LocalUsageEstimate {
        LocalUsageEstimate(snapshot: snapshot(now: now), budget: budget)
    }

    static func shortSummary(_ snapshot: LocalUsageSnapshot) -> String {
        "5h ~\(formatTokens(snapshot.fiveHourTokens)) tok"
    }

    static func shortSummary(_ estimate: LocalUsageEstimate) -> String {
        "5h ~\(estimate.fiveHourUsedPct)% used"
    }

    static func detailedSummary(_ estimate: LocalUsageEstimate) -> (title: String, body: String) {
        let title = "Approx local usage estimate"
        let body = """
        Last 5 hours: ~\(estimate.fiveHourUsedPct)% used, ~\(estimate.fiveHourLeftPct)% left
        Tokens: \(formatTokens(estimate.snapshot.fiveHourTokens)) / \(formatTokens(estimate.budget.fiveHourTokens))
        Turns: \(estimate.snapshot.fiveHourTurns)

        Last 7 days: ~\(estimate.sevenDayUsedPct)% used, ~\(estimate.sevenDayLeftPct)% left
        Tokens: \(formatTokens(estimate.snapshot.sevenDayTokens)) / \(formatTokens(estimate.budget.sevenDayTokens))
        Turns: \(estimate.snapshot.sevenDayTurns)

        These percentages are local estimates against configurable token budgets, not real Anthropic account quota data.
        """
        return (title, body)
    }

    private static func loadTurnUsage() -> [TurnUsage] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard let enumerator = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var deduped: [String: TurnUsage] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                let lineData = Data(line.utf8)
                guard
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestampText = json["timestamp"] as? String,
                      let timestamp = parseDate(timestampText) else { continue }

                let totalTokens =
                    intValue(usage["input_tokens"]) +
                    intValue(usage["output_tokens"]) +
                    intValue(usage["cache_creation_input_tokens"]) +
                    intValue(usage["cache_read_input_tokens"])

                guard totalTokens > 0 else { continue }

                let requestID = (json["requestId"] as? String) ?? (json["uuid"] as? String) ?? UUID().uuidString
                let existing = deduped[requestID]
                if existing == nil || totalTokens >= existing!.totalTokens {
                    deduped[requestID] = TurnUsage(timestamp: timestamp, totalTokens: totalTokens)
                }
            }
        }

        return Array(deduped.values)
    }

    private static func parseDate(_ text: String) -> Date? {
        for parser in iso8601Parsers {
            if let date = parser.date(from: text) { return date }
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        default:
            return 0
        }
    }

    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
