import Foundation
import HealthKit

/// Sends to Home Assistant when Apple Health gets new data for a selected metric: one `HKObserverQuery` per type,
/// with background delivery (iOS wakes the app, at most once an hour per type, even when it is not running).
/// iOS forgets the queries when the app ends: `start` runs at every launch, and again when the selection changes.
@MainActor
enum HealthObserver {
    private static let store = HKHealthStore()
    private static var queries: [HKObserverQuery] = []
    private static var observed: Set<HKSampleType> = []

    static func start(for selected: Set<String>) async {
        var types = Catalog.sampleTypes(for: selected)
        if Keychain.webhookURL == nil || !HKHealthStore.isHealthDataAvailable() {
            types = []
        } else if (try? await store.statusForAuthorizationRequest(toShare: [], read: Catalog.readTypes)) != .unnecessary {
            // Access not asked yet: the first sync asks for it (in the foreground), then calls `start` again.
            return
        }
        guard types != observed else { return }

        for q in queries { store.stop(q) }
        queries = []
        for type in observed.subtracting(types) {
            store.disableBackgroundDelivery(for: type) { _, _ in }
        }
        observed = types

        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // `completion` tells iOS the update was handled (otherwise it retries, then stops waking the app).
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await Sync.shared.send(.health)
                    completion()
                }
            }
            store.execute(query)
            queries.append(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }
}
