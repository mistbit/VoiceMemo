import SwiftUI

@main
struct VoiceMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = SettingsStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
                .onAppear {
                    StorageManager.shared.setup(settings: settings)
                }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force the app to be a regular app (shows in Dock, has UI)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Ensure main window comes to front
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
