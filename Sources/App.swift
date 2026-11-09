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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Drop an app on Crumbs' Dock icon, or run: open -a Crumbs /Applications/Some.app
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

    /// Opening Crumbs again (Finder, Spotlight, Launchpad) while it waits in the menu bar: show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Model.shared.showWindow() } }
        return true
    }

    /// When the main window closes while watching, hide the Dock icon (Crumbs lives in the menu bar).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, w.title == "Crumbs" else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Model.shared.goHome()            // next time the window opens, start on the welcome screen
                    let mainStillOpen = NSApp.windows.contains { $0 !== w && $0.title == "Crumbs" && $0.isVisible }
                    if Model.shared.watchDeletedApps, !mainStillOpen { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
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
                .frame(minWidth: 820, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Model.shared.checkForUpdates(userAsked: true) } }
            }
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") { NSWorkspace.shared.open(Updater.reportProblemURL()) }
                Button("Suggest an Idea…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/issues/new?template=idea.yml")!)
                }
                Divider()
                Button("Crumbs on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!) }
            }
            // Note: ⌘Z stays normal text undo (e.g. in the search box). Putting files back is ⌥⌘Z.
            CommandMenu("Clean") {
                Button("Put Back Last Removal") { Model.shared.undoLastMove() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                Button("Find Orphaned Files") { Model.shared.showOrphans(); Model.shared.showWindow() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Refresh") { Model.shared.refresh() }
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
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Button("Open Crumbs") { model.showWindow() }
        Button("Find Orphaned Files") { model.showOrphans(); model.showWindow() }
        Button("Check for Updates…") { Task { await model.checkForUpdates(userAsked: true) } }
        Button("Report a Problem…") { NSWorkspace.shared.open(Updater.reportProblemURL()) }
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
            Section("Watching") {
                Toggle("Watch for deleted apps", isOn: $model.watchDeletedApps)
                Text("When you drag an app to the Trash in Finder, Crumbs shows what it left behind. It waits in the menu bar while this is on.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $model.autoUpdates)
                HStack {
                    Text("Crumbs \(Updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Task { await model.checkForUpdates(userAsked: true) } }
                        .disabled(model.updateStatus != nil)
                }
                Text("Crumbs only goes online to check GitHub for a new version. It sends nothing about you.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Help") {
                HStack {
                    Text("Something not working?")
                    Spacer()
                    Button("Report a Problem…") { NSWorkspace.shared.open(Updater.reportProblemURL()) }
                }
            }
            Section("Protected apps") {
                if model.protectedIDs.isEmpty {
                    Text("None yet. Right-click an app in the list and choose “Protect from Removal”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.protectedIDs, id: \.self) { id in
                    HStack {
                        Text((model.apps + model.plugins).first { $0.bundleID.lowercased() == id.lowercased() }?.displayName ?? id)
                        Spacer()
                        Button("Remove") { model.protectedIDs.removeAll { $0 == id } }.buttonStyle(.link)
                    }
                }
                Text("Apple's own apps and apps locked by macOS are always protected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 580)
    }
}
