import Foundation
import BackgroundTasks
import HealthKit
import UIKit

/// Why a sync was started. The raw value is sent as `source` (Home Assistant uses `manual` to trigger the summary).
enum SyncSource: String {
    case health, link, manual, background, settings, history

    /// Started by iOS, not by the user: throttled, and a locked iPhone is not reported as a failure.
    var automatic: Bool { self == .health || self == .background }

    var label: String {
        switch self {
        case .health: return String(localized: "new Health data")
        case .link: return String(localized: "link")
        case .manual: return String(localized: "pull to refresh")
        case .background: return String(localized: "background")
        case .settings: return String(localized: "settings")
        case .history: return String(localized: "history")
        }
    }
}

enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in project.yml (`$(PRODUCT_BUNDLE_IDENTIFIER).send`).
    static let identifier = (Bundle.main.bundleIdentifier ?? "healthhook") + ".send"

    /// Asks iOS for a background refresh, `delay` from now at the earliest (iOS picks the actual time).
    /// A new request replaces the pending one.
    static func schedule(after delay: TimeInterval = 6 * 3600) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(delay)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// An automatic sync (new Health data, background refresh) and what came of it: shows whether and when iOS wakes the
/// app. The last ones are listed in the app and sent to Home Assistant with each payload (`wakes`).
struct Wake: Codable, Identifiable {
    enum Result: String, Codable {
        case sent, locked, throttled, failed
    }
    /// ISO 8601 (UTC), as in the payload.
    var at: String
    var source: String
    var result: Result
    /// false = the app was open (e.g. the sync that follows opening it), true = iOS ran it in the background.
    var background: Bool
    /// Identical results in a row (e.g. several "throttled" when many data types change at once).
    var count = 1

    var id: String { at + source + result.rawValue }
    var date: Date? { try? Date(at, strategy: .iso8601) }

    var label: String {
        switch result {
        case .sent: return String(localized: "Sent")
        case .locked: return String(localized: "iPhone locked")
        case .throttled: return String(localized: "Skipped (sent less than 5 minutes ago)")
        case .failed: return String(localized: "Failed")
        }
    }
}

enum SendError: LocalizedError {
    case http(Int)
    case invalidURL
    case notHTTPS

    var errorDescription: String? {
        switch self {
        case .http(let code): return String(localized: "Home Assistant answered HTTP \(String(code))")
        case .invalidURL: return String(localized: "Invalid webhook URL")
        case .notHTTPS: return String(localized: "The webhook URL must start with https:// (iOS blocks unencrypted connections)")
        }
    }
}

@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()

    @Published private(set) var status: String
    /// Top-level values of the last payload sent (kept between launches).
    @Published private(set) var last: [String: Double?]?
    /// Webhook URL received from a `healthhook://config` link, waiting for the user's confirmation.
    @Published private(set) var proposedURL: String?
    @Published private(set) var sending = false
    @Published private(set) var importing = false
    @Published private(set) var urlConfigured: Bool
    /// Ids (`Metric.id`) of the metrics to send.
    @Published private(set) var selected: Set<String>
    /// Automatic syncs, newest first (kept between launches).
    @Published private(set) var wakes: [Wake] = []

    private let health = HealthReader()
    private var lastAttempt: Date?
    /// Automatic syncs (new Health data, background refresh) at most every 5 minutes: several types often change at once.
    private static let automaticInterval: TimeInterval = 5 * 60

    private init() {
        status = UserDefaults.standard.string(forKey: "status") ?? String(localized: "Never sent")
        urlConfigured = Keychain.webhookURL != nil
        if let ids = UserDefaults.standard.array(forKey: "selectedMetrics") as? [String] {
            selected = Set(ids)
        } else {
            selected = Catalog.defaults
        }
        if let data = UserDefaults.standard.data(forKey: "lastValues") {
            last = try? JSONDecoder().decode([String: Double?].self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: "wakes") {
            wakes = (try? JSONDecoder().decode([Wake].self, from: data)) ?? []
        }
    }

    func toggle(_ id: String, on: Bool) {
        var ids = selected
        if on { ids.insert(id) } else { ids.remove(id) }
        select(ids)
    }

    func select(_ ids: Set<String>) {
        selected = ids
        UserDefaults.standard.set(Array(ids), forKey: "selectedMetrics")
        Task { await HealthObserver.start(for: ids) }
    }

    func saveURL(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.webhookURL = clean.isEmpty ? nil : clean
        urlConfigured = Keychain.webhookURL != nil
        Task {
            await send(.settings, force: true)
            await HealthObserver.start(for: selected)
        }
    }

    /// `healthhook://config?url=<webhook URL, percent-encoded>` (Home Assistant notification, QR code…).
    /// Nothing is saved before the user confirms: any web page can open such a link.
    func propose(_ link: URL) {
        let text = URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, let url = URL(string: text), url.host() != nil else {
            update(SendError.invalidURL.localizedDescription)
            return
        }
        guard url.scheme == "https" else {
            update(SendError.notHTTPS.localizedDescription)
            return
        }
        proposedURL = text
    }

    func dismissProposal() {
        proposedURL = nil
    }

    private func webhook() -> URL? {
        guard let text = Keychain.webhookURL else {
            update(String(localized: "Enter the webhook URL below"))
            return nil
        }
        guard let url = URL(string: text), url.host() != nil else {
            update(SendError.invalidURL.localizedDescription)
            return nil
        }
        guard url.scheme == "https" else {
            update(SendError.notHTTPS.localizedDescription)
            return nil
        }
        guard !selected.isEmpty else {
            update(String(localized: "No data selected"))
            return nil
        }
        return url
    }

    /// `force` skips the 20-second de-duplication (opening from a link = foreground + link, almost simultaneous).
    func send(_ source: SyncSource, force: Bool = false) async {
        // Not logged: another sync is running or has just run (its own result is logged).
        guard !sending, !importing else { return }
        if !force, let d = lastAttempt, Date().timeIntervalSince(d) < 20 { return }
        if source.automatic, let d = UserDefaults.standard.object(forKey: "lastSuccess") as? Date,
           Date().timeIntervalSince(d) < Self.automaticInterval { return log(source, .throttled) }
        guard let url = webhook() else { return }
        sending = true
        lastAttempt = Date()
        defer { sending = false }

        do {
            var payload = try await health.read(source: source.rawValue, selected: selected)
            payload.wakes = Array(wakes.prefix(Self.wakesSent))
            try await post(payload, to: url)
            log(source, .sent)
            last = payload.values
            UserDefaults.standard.set(try? JSONEncoder().encode(payload.values), forKey: "lastValues")
            UserDefaults.standard.set(Date(), forKey: "lastSuccess")
            update(String(localized: "Sent (\(source.label)) on \(Date().formatted(date: .abbreviated, time: .shortened))"))
            // First sync: Health access has just been granted, the observers can start.
            await HealthObserver.start(for: selected)
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // Locked iPhone: normal for an automatic sync, not worth a failure status. iOS only wakes the app again
            // for newer Health data (at most once an hour): a background refresh is asked for soon, to catch up.
            log(source, .locked)
            if source.automatic {
                BackgroundRefresh.schedule(after: Self.retryAfterLocked)
            } else {
                update(String(localized: "Failed (\(source.label)): Health is unreadable while the iPhone is locked"))
            }
        } catch {
            log(source, .failed)
            update(String(localized: "Failed (\(source.label)): \(error.localizedDescription)"))
        }
    }

    /// Wakes kept in the app / sent to Home Assistant with each payload.
    private static let wakesKept = 30
    private static let wakesSent = 10
    /// Earliest background refresh after a wake-up while the iPhone was locked (iOS picks the actual time).
    private static let retryAfterLocked: TimeInterval = 15 * 60

    /// Logs the result of an automatic sync (other sources show their result in the status line).
    private func log(_ source: SyncSource, _ result: Wake.Result) {
        guard source.automatic else { return }
        let background = UIApplication.shared.applicationState != .active
        if var first = wakes.first, first.source == source.rawValue, first.result == result,
           first.background == background, result != .sent {
            first.count += 1
            wakes[0] = first
        } else {
            let at = Date().formatted(.iso8601)
            wakes.insert(Wake(at: at, source: source.rawValue, result: result, background: background), at: 0)
            if wakes.count > Self.wakesKept { wakes.removeLast(wakes.count - Self.wakesKept) }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(wakes), forKey: "wakes")
    }

    /// History import for the Home Assistant journal: `days` only (sensors untouched), source `history`,
    /// in batches of 30 days (Home Assistant passes the JSON to a script as an argument, ~128 KB max), from yesterday back.
    func importHistory(days total: Int = 365) async {
        guard !sending, !importing else { return }
        guard let url = webhook() else { return }
        importing = true
        defer { importing = false }
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        var done = 0
        do {
            while done < total {
                update(String(localized: "Importing history: \(String(done)) / \(String(total)) days…"))
                let n = min(30, total - done)
                let lastDay = cal.date(byAdding: .day, value: -done, to: yesterday)!
                let payload = try await health.read(source: SyncSource.history.rawValue, selected: selected,
                                                    lastDay: lastDay, dayCount: n, withValues: false)
                try await post(payload, to: url)
                done += n
            }
            update(String(localized: "History sent: \(String(total)) days (\(Date().formatted(date: .abbreviated, time: .shortened)))"))
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            update(String(localized: "Import stopped after \(String(done)) days: iPhone locked"))
        } catch {
            update(String(localized: "Import stopped after \(String(done)) days: \(error.localizedDescription)"))
        }
    }

    private func post(_ payload: Payload, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SendError.http(code) }
    }

    private func update(_ text: String) {
        status = text
        UserDefaults.standard.set(text, forKey: "status")
    }
}
