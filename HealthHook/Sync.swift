import Foundation
import BackgroundTasks
import HealthKit

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
        guard !sending, !importing else { return }
        if !force, let d = lastAttempt, Date().timeIntervalSince(d) < 20 { return }
        if source.automatic, let d = UserDefaults.standard.object(forKey: "lastSuccess") as? Date,
           Date().timeIntervalSince(d) < Self.automaticInterval { return }
        guard let url = webhook() else { return }
        sending = true
        lastAttempt = Date()
        defer { sending = false }

        do {
            let payload = try await health.read(source: source.rawValue, selected: selected)
            try await post(payload, to: url)
            last = payload.values
            UserDefaults.standard.set(try? JSONEncoder().encode(payload.values), forKey: "lastValues")
            UserDefaults.standard.set(Date(), forKey: "lastSuccess")
            update(String(localized: "Sent (\(source.label)) on \(Date().formatted(date: .abbreviated, time: .shortened))"))
            // First sync: Health access has just been granted, the observers can start.
            await HealthObserver.start(for: selected)
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // Locked iPhone: normal for an automatic sync (the next one will catch up), not worth a failure status.
            if !source.automatic {
                update(String(localized: "Failed (\(source.label)): Health is unreadable while the iPhone is locked"))
            }
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
