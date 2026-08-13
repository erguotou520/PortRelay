import SwiftUI

@main
struct PortRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 620)
                .alert(
                    "提示",
                    isPresented: Binding(
                        get: { store.alertMessage != nil },
                        set: { if !$0 { store.alertMessage = nil } }
                    )
                ) {
                    Button("确定") { store.alertMessage = nil }
                } message: {
                    Text(store.alertMessage ?? "")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppStore.shared.forwardManager.stopAll()
            AppStore.shared.kubernetesForwardManager.stopAll()
            AppStore.shared.sessionManager.stopAll()
        }
    }
}
