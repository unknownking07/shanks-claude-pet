import Foundation
import WebKit

/// Fetches Claude web usage using the authenticated claude.ai browser session.
/// Uses cookies persisted in WKWebView's default website data store.
enum UsageAPIClient {

    struct Usage {
        let fiveHourPct: Double
        let sevenDayPct: Double
        let fiveHourResetsAt: Date?
        let sevenDayResetsAt: Date?
    }

    private enum DefaultsKey {
        static let organizationID = "claudeWebOrganizationID"
    }

    private static let defaults = UserDefaults.standard
    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!
    private static let minFetchInterval: TimeInterval = 120
    private static var lastFetchTime: Date?

    static func resetCooldown() { lastFetchTime = nil }

    static func hasSavedSession() -> Bool {
        defaults.string(forKey: DefaultsKey.organizationID)?.isEmpty == false
    }

    static func fetch(completion: @escaping (Usage?) -> Void) {
        if let last = lastFetchTime, Date().timeIntervalSince(last) < minFetchInterval {
            NSLog("[UsageAPIClient] Skipping — cooldown (%.0fs)", Date().timeIntervalSince(last))
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lastFetchTime = Date()

        currentCookieHeader { cookieHeader in
            guard let cookieHeader else {
                NSLog("[UsageAPIClient] No claude.ai session cookies available")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            organizationID(cookieHeader: cookieHeader) { organizationID in
                guard let organizationID else {
                    NSLog("[UsageAPIClient] Could not resolve claude.ai organization")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let url = URL(string: "https://claude.ai/api/organizations/\(organizationID)/usage")!
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.httpMethod = "GET"
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
                request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
                request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

                URLSession.shared.dataTask(with: request) { data, response, error in
                    guard let http = response as? HTTPURLResponse else {
                        NSLog("[UsageAPIClient] No usage response: %@", error?.localizedDescription ?? "unknown")
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    guard (200..<300).contains(http.statusCode), let data else {
                        NSLog("[UsageAPIClient] Usage HTTP %d", http.statusCode)
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let usage = parseUsage(data)
                    DispatchQueue.main.async { completion(usage) }
                }.resume()
            }
        }
    }

    static func currentCookieHeader(completion: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let claudeCookies = cookies
                .filter { ($0.domain.contains("claude.ai") || $0.domain.contains(".claude.ai")) && !$0.name.isEmpty }
                .sorted { $0.name < $1.name }

            guard claudeCookies.contains(where: { $0.name == "sessionKey" }) else {
                completion(nil)
                return
            }

            let header = claudeCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            completion(header.isEmpty ? nil : header)
        }
    }

    static func organizationID(cookieHeader: String, completion: @escaping (String?) -> Void) {
        if let cached = defaults.string(forKey: DefaultsKey.organizationID), !cached.isEmpty {
            completion(cached)
            return
        }

        var request = URLRequest(url: organizationsURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/settings/account", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let http = response as? HTTPURLResponse else {
                NSLog("[UsageAPIClient] No org response: %@", error?.localizedDescription ?? "unknown")
                completion(nil)
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                NSLog("[UsageAPIClient] Organization HTTP %d", http.statusCode)
                completion(nil)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil)
                return
            }

            let organizationID = json.first.flatMap { $0["uuid"] as? String }
            if let organizationID, !organizationID.isEmpty {
                defaults.set(organizationID, forKey: DefaultsKey.organizationID)
            }
            completion(organizationID)
        }.resume()
    }

    static func clearSavedSession() {
        defaults.removeObject(forKey: DefaultsKey.organizationID)
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains("claude.ai") || cookie.domain.contains(".claude.ai") {
                store.delete(cookie)
            }
        }
    }

    private static func parseUsage(_ data: Data) -> Usage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]

        guard let fiveHour, let sevenDay else { return nil }

        let fiveHourPct = normalizePercent(fiveHour["utilization"])
        let sevenDayPct = normalizePercent(sevenDay["utilization"])
        let fiveReset = (fiveHour["resets_at"] as? String).flatMap(parseISO8601)
        let sevenReset = (sevenDay["resets_at"] as? String).flatMap(parseISO8601)

        return Usage(
            fiveHourPct: fiveHourPct,
            sevenDayPct: sevenDayPct,
            fiveHourResetsAt: fiveReset,
            sevenDayResetsAt: sevenReset
        )
    }

    private static func normalizePercent(_ any: Any?) -> Double {
        switch any {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value) ?? 0
        default:
            return 0
        }
    }

    private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFrac, plain]
    }()

    private static func parseISO8601(_ text: String) -> Date? {
        for formatter in iso8601Formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
