import SwiftUI

/// Sends Apple Health data to a Home Assistant webhook:
/// - every time the app comes to the foreground;
/// - from the `healthhook://send` link (e.g. a Home Assistant notification);
/// - in the background whenever iOS allows it (app refresh, 6 hours after the previous one at the earliest, not guaranteed).
@main
struct HealthHookApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var sync = Sync.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sync)
                .onOpenURL { url in
                    guard url.scheme == "healthhook", url.host == "send" else { return }
                    Task { await sync.send(.link) }
                }
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await sync.send(.open) }
            case .background:
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            await Sync.shared.send(.background)
        }
    }
}
