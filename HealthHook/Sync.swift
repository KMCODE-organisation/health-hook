import Foundation
import BackgroundTasks
import HealthKit

/// Why a sync was started. The raw value is sent as `source` (Home Assistant uses `manual` to trigger the summary).
enum SyncSource: String {
    case open, link, manual, background, settings, history

    var label: String {
        switch self {
        case .open: return String(localized: "app opened")
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

    /// Asks iOS for a background refresh, 6 hours from now at the earliest (iOS picks the actual time).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

enum SendError: LocalizedError {
    case http(Int)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .http(let code): return String(localized: "Home Assistant answered HTTP \(String(code))")
        case .invalidURL: return String(localized: "Invalid webhook URL")
        }
    }
}

@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()

    @Published private(set) var status: String
    @Published private(set) var last: Payload?
    @Published private(set) var sending = false
    @Published private(set) var importing = false
    @Published private(set) var urlConfigured: Bool
    /// Ids (`Metric.id`) of the metrics to send.
    @Published private(set) var selected: Set<String>

    private let health = HealthReader()
    private var lastAttempt: Date?

    private init() {
        status = UserDefaults.standard.string(forKey: "status") ?? String(localized: "Never sent")
        urlConfigured = Keychain.webhookURL != nil
        if let ids = UserDefaults.standard.array(forKey: "selectedMetrics") as? [String] {
            selected = Set(ids)
        } else {
            selected = Catalog.defaults
        }
    }

    func toggle(_ id: String, on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
        UserDefaults.standard.set(Array(selected), forKey: "selectedMetrics")
    }

    func select(_ ids: Set<String>) {
        selected = ids
        UserDefaults.standard.set(Array(ids), forKey: "selectedMetrics")
    }

    func saveURL(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.webhookURL = clean.isEmpty ? nil : clean
        urlConfigured = Keychain.webhookURL != nil
        Task { await send(.settings, force: true) }
    }

    private func webhook() -> URL? {
        guard let text = Keychain.webhookURL else {
            update(String(localized: "Enter the webhook URL below"))
            return nil
        }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else {
            update(SendError.invalidURL.localizedDescription)
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
        guard !sending, !importing else { return }
        if !force, let d = lastAttempt, Date().timeIntervalSince(d) < 20 { return }
        guard let url = webhook() else { return }
        sending = true
        lastAttempt = Date()
        defer { sending = false }

        do {
            let payload = try await health.read(source: source.rawValue, selected: selected)
            try await post(payload, to: url)
            last = payload
            update(String(localized: "Sent (\(source.label)) on \(Date().formatted(date: .abbreviated, time: .shortened))"))
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            update(String(localized: "Failed (\(source.label)): Health is unreadable while the iPhone is locked"))
        } catch {
            update(String(localized: "Failed (\(source.label)): \(error.localizedDescription)"))
        }
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
