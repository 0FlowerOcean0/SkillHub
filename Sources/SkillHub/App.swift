import SwiftUI

@main
struct SkillHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state: AppState

    init() {
        AppPreferences.migrateLegacyBundleIfNeeded()
        _state = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        WindowGroup("SkillHub") {
            NewContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { state.refresh() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        NSApp.applicationIconImage = NSImage(named: "AppIcon")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
