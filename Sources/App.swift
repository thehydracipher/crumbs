// App.swift - entry point, window, menu bar icon and settings.
// Part of Crumbs. MIT License.

import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, first.hasPrefix("--"), !first.hasPrefix("-NS") {
            exit(CLI.run(args))
        }
        CrumbsApp.main()
    }
}

/// Lets you drop an app on Crumbs' Dock icon, or run: open -a Crumbs /Applications/Some.app
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let app = urls.lazy.compactMap(TargetApp.load).first else { return }
        Task { @MainActor in
            Model.shared.open(app)
            Model.shared.showWindow()
        }
    }

    /// While watching for deleted apps, keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !Model.shared.watchDeletedApps }
    }
}

struct CrumbsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Don't observe the whole Model here: any change would rebuild every window and menu
    // in a loop (that caused a crash). Only this one setting is needed at this level.
    @AppStorage("watchDeletedApps") private var watchDeletedApps = true
    private let model = Model.shared

    var body: some Scene {
        Window("Crumbs", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Clean") {
                Button("Find Orphaned Files") { Model.shared.showOrphans(); Model.shared.showWindow() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Reload App List") { Model.shared.reloadApps() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        // Shown only while "Watch for deleted apps" is on.
        MenuBarExtra(isInserted: $watchDeletedApps) {
            MenuBarMenu().environmentObject(model)
        } label: {
            MenuBarLabel()
        }
    }
}

/// Always on screen while watching, so it can re-open the window when an app is deleted.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: "sparkles")
            .onReceive(Model.shared.$openWindowRequest.dropFirst()) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Crumbs") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Find Orphaned Files") {
            model.showOrphans(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Toggle("Watch for Deleted Apps", isOn: $model.watchDeletedApps)
        Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
        Divider()
        Button("Quit Crumbs") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Watch for deleted apps", isOn: $model.watchDeletedApps)
            Text("When you drag an app to the Trash in Finder, Crumbs shows what it left behind. Crumbs stays in the menu bar while this is on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            Text("Starts Crumbs when you log in, so it can keep watching.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
