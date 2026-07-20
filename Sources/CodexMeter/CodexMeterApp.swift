import SwiftUI

@main
struct CodexMeterApp: App {
    @UIApplicationDelegateAdaptor(CodexMeterNotificationDelegate.self) private var appDelegate
    @StateObject private var model = MeterViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .backgroundTask(.appRefresh(UsageBackgroundRefresh.identifier)) {
            await UsageBackgroundRefresh.run()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { UsageBackgroundRefresh.schedule() }
        }
    }
}
