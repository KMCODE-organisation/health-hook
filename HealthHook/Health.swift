import Foundation
import HealthKit

private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Whole numbers are encoded without ".0".
private func write(_ v: Double, _ c: inout KeyedEncodingContainer<Key>, _ key: String) throws {
    if v == v.rounded(), abs(v) < 1e15 { try c.encode(Int(v), forKey: Key(key)) }
    else { try c.encode(v, forKey: Key(key)) }
}

/// One day (midnight to midnight, phone time zone). Sleep = the night that ends on that day (wake-up before 6 pm).
struct Day: Encodable {
    var date: String
    var values: [String: Double]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(date, forKey: Key("date"))
        for (k, v) in values { try write(v, &c, k) }
    }
}

/// JSON body posted to the webhook (see README, "Payload").
/// - One top-level key per selected metric: a number, or `null` when selected but without data
///   (cumulative metric: nothing today; other: never measured or read error). Unselected metric = key absent.
/// - `dates`: date of the latest sample for "latest value" metrics.
/// - `days`: the last 7 days (daily totals / averages), used by the Home Assistant journal.
struct Payload: Encodable {
    var values: [String: Double?]
    var dates: [String: String]
    var days: [Day]
    var source: String
    var sentAt: String
    /// End of validity of the app's signing profile (free Apple account: 7 days).
    var expiresAt: String? = nil

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (k, v) in values {
            if let v { try write(v, &c, k) } else { try c.encodeNil(forKey: Key(k)) }
        }
        try c.encode(dates, forKey: Key("dates"))
        try c.encode(days, forKey: Key("days"))
        try c.encode(source, forKey: Key("source"))
        try c.encode(sentAt, forKey: Key("sent_at"))
        if let expiresAt { try c.encode(expiresAt, forKey: Key("expires_at")) }
    }
}

final class HealthReader: @unchecked Sendable {
    private let store = HKHealthStore()
    private let cal = Calendar.current

    private enum Result {
        case quantity(String, HKStatisticsCollection, HKQuantitySample?)
        case nights([Date: Double])
        /// Read error for this metric only: the others are still sent (value `null`).
        case failed(String)
    }

    /// Reads `dayCount` days ending on `lastDay` (today by default).
    /// `withValues: false` (history import): `days` only, no top-level values (Home Assistant sensors untouched).
    func read(source: String, selected: Set<String>, lastDay: Date? = nil, dayCount: Int = 7,
              withValues: Bool = true) async throws -> Payload {
        // The authorization sheet only appears once per data type.
        try await store.requestAuthorization(toShare: [], read: Catalog.readTypes)

        let end = cal.startOfDay(for: lastDay ?? Date())
        let start = cal.date(byAdding: .day, value: -(dayCount - 1), to: end)!
        let limit: Date? = lastDay == nil ? nil : cal.date(byAdding: .day, value: 1, to: end)!
        let chosen = Catalog.metrics.filter { selected.contains($0.id) }

        var collections: [String: HKStatisticsCollection] = [:]
        var latest: [String: HKQuantitySample] = [:]
        var nights: [Date: Double] = [:]
        try await withThrowingTaskGroup(of: Result.self) { group in
            for m in chosen {
                group.addTask {
                    do {
                        return try await self.read(m, from: start, to: limit, withLatest: withValues)
                    } catch let e as HKError where e.code == .errorDatabaseInaccessible {
                        throw e   // iPhone locked: nothing is readable, no point sending
                    } catch {
                        return .failed(m.id)
                    }
                }
            }
            for try await r in group {
                switch r {
                case .quantity(let id, let c, let s):
                    collections[id] = c
                    latest[id] = s
                case .nights(let n):
                    nights = n
                case .failed:
                    break
                }
            }
        }

        var days: [Day] = []
        for offset in 0..<dayCount {
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            var v: [String: Double] = [:]
            for m in chosen {
                if m.kind == .sleep {
                    v[m.id] = nights[day].map { rounded($0, 1) }
                    continue
                }
                guard let s = collections[m.id]?.statistics(for: day) else { continue }
                if m.kind == .cumulative {
                    v[m.id] = value(s.sumQuantity(), m)
                } else {
                    v[m.averageKey] = value(s.averageQuantity(), m)
                    if m.minMax {
                        v[m.id + "_min"] = value(s.minimumQuantity(), m)
                        v[m.id + "_max"] = value(s.maximumQuantity(), m)
                    }
                }
            }
            days.append(Day(date: Self.dayFormat.string(from: day), values: v))
        }

        // Top level: today's total for cumulative metrics and sleep, latest sample for the others
        // (+ today's min/avg/max for heart rate). Every selected key is present: `nil` → `null`.
        let today = days.last!.values
        var top: [String: Double?] = [:]
        var dates: [String: String] = [:]
        let iso = ISO8601DateFormatter()
        for m in chosen where withValues {
            switch m.kind {
            case .cumulative, .sleep:
                top[m.id] = .some(today[m.id])
            case .discrete:
                let s = latest[m.id]
                top[m.id] = .some(value(s?.quantity, m))
                if let s { dates[m.id] = iso.string(from: s.endDate) }
                if m.minMax { for k in [m.id + "_min", m.averageKey, m.id + "_max"] { top[k] = .some(today[k]) } }
            }
        }

        return Payload(values: top, dates: dates, days: days, source: source,
                       sentAt: iso.string(from: Date()),
                       expiresAt: withValues ? SigningProfile.expiration.map { iso.string(from: $0) } : nil)
    }

    // MARK: - Queries

    private func read(_ m: Metric, from start: Date, to end: Date?, withLatest: Bool) async throws -> Result {
        guard let id = m.quantity else { return .nights(try await sleepByNight(from: start, to: end)) }
        let c = try await statistics(id, m.options, from: start, to: end)
        let s = withLatest && m.kind == .discrete ? try await latestSample(id) : nil
        return .quantity(m.id, c, s)
    }

    /// Day-by-day statistics (Health de-duplicates sources, e.g. steps from the iPhone and a watch).
    private func statistics(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions,
                            from start: Date, to end: Date?) async throws -> HKStatisticsCollection {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        return try await query.result(for: store)
    }

    private func latestSample(_ id: HKQuantityTypeIdentifier) async throws -> HKQuantitySample? {
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try await query.result(for: store).first
    }

    /// Hours asleep per night, keyed by the start of the wake-up day. "Asleep" stages from every source are merged
    /// (overlapping intervals counted once); awake and in-bed are excluded.
    private func sleepByNight(from start: Date, to end: Date?) async throws -> [Date: Double] {
        let predicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-12 * 3600), end: end)
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]

        var intervals: [(start: Date, end: Date)] = []
        for s in try await query.result(for: store) where asleep.contains(s.value) {
            if let i = intervals.indices.last, s.startDate <= intervals[i].end {
                intervals[i].end = max(intervals[i].end, s.endDate)
            } else {
                intervals.append((s.startDate, s.endDate))
            }
        }

        var byDay: [Date: Double] = [:]
        for (s, e) in intervals {
            var day = cal.startOfDay(for: e)
            if cal.component(.hour, from: e) >= 18 {
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
            byDay[day, default: 0] += e.timeIntervalSince(s) / 3600
        }
        return byDay
    }

    // MARK: - Helpers

    private func rounded(_ v: Double, _ decimals: Int) -> Double {
        let p = pow(10, Double(decimals))
        return (v * p).rounded() / p
    }

    private func value(_ q: HKQuantity?, _ m: Metric) -> Double? {
        q.map { rounded($0.doubleValue(for: m.unit) * m.factor, m.decimals) }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Signing profile embedded in the app (`embedded.mobileprovision`: a CMS envelope around an XML plist).
enum SigningProfile {
    /// Expiration date (free Apple account: 7 days after install). `nil` in the simulator.
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()
}
