import SwiftUI

/// Sends Apple Health data to a Home Assistant webhook:
/// - when Apple Health gets new data (HealthKit background delivery, see `HealthObserver`), even when the app is closed;
/// - on pull-to-refresh, and from the `healthhook://send` link (e.g. a Home Assistant notification);
/// - in the background whenever iOS allows it (app refresh, 6 hours after the previous one at the earliest, not guaranteed).
/// The `healthhook://config?url=<webhook URL>` link proposes a webhook URL (confirmed by the user before it is saved).
@main
struct HealthHookApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var sync = Sync.shared

    init() {
        // At every launch, including when iOS launches the app in the background to deliver new Health data.
        Task { await HealthObserver.start(for: Sync.shared.selected) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sync)
                .onOpenURL { url in
                    guard url.scheme == "healthhook" else { return }
                    switch url.host() {
                    case "send": Task { await sync.send(.link, force: true) }
                    case "config": sync.propose(url)
                    default: break
                    }
                }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            await Sync.shared.send(.background)
        }
    }
}
