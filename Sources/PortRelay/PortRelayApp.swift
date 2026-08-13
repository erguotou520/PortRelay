import SwiftUI

@main
struct PortRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
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
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppStore.shared.forwardManager.stopAll()
        }
    }
}
