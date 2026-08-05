import SwiftUI

@main
struct SkillHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

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

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "appiconset", subdirectory: "Assets.xcassets"),
           let data = try? Data(contentsOf: iconURL.appendingPathComponent("icon_512x512.png")),
           let image = NSImage(data: data) {
            NSApp.applicationIconImage = image
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
