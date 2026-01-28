import SwiftUI

private extension NSNotification.Name {
    static let systemThemeChanged = NSNotification.Name("SystemThemeChanged")
    static let appleInterfaceThemeChanged = NSNotification.Name("AppleInterfaceThemeChangedNotification")
}

@main
struct VoiceMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = SettingsStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
                .onAppear {
                    StorageManager.shared.setup(settings: settings)
                    applyTheme(settings.appTheme)
                }
                .onChange(of: settings.appTheme) { newTheme in
                    applyTheme(newTheme)
                }
                .onReceive(NotificationCenter.default.publisher(for: .systemThemeChanged)) { _ in
                    if settings.appTheme == .system {
                        applyTheme(.system)
                    }
                }
        }
    }

    private func applyTheme(_ theme: SettingsStore.AppTheme) {
        let appearance: NSAppearance?
        switch theme {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeChangeObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        
        themeChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .appleInterfaceThemeChanged,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .systemThemeChanged, object: nil)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let observer = themeChangeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            themeChangeObserver = nil
        }
    }
}
