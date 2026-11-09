// Model.swift - the app's state and actions.
// Part of Crumbs. MIT License.

import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    static let orphansID = "special:orphans"

    // What's on screen
    @Published var apps: [TargetApp] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { selectionChanged() } } }
    @Published var current: TargetApp?
    @Published var showingOrphans = false
    @Published var items: [FoundItem] = []
    @Published var checked: Set<String> = []
    @Published var scanning = false
    @Published var search = ""
    @Published var notice: String?
    @Published var dropTargeted = false
    @Published var confirming = false

    // Quitting a running app
    @Published var runningTick = 0          // bumps when any app starts or quits, so the UI refreshes
    @Published var quitting = false
    @Published var offerForceQuit = false

    // Watching for deleted apps
    @Published var openWindowRequest = 0
    @Published var watchDeletedApps: Bool {
        didSet { UserDefaults.standard.set(watchDeletedApps, forKey: "watchDeletedApps"); updateWatcher() }
    }
    @Published var openAtLogin = false
    private var watcher: AppWatcher?
    private var trashedByUs: Set<String> = []   // bundle IDs we removed ourselves (don't pop up for those)

    private init() {
        watchDeletedApps = UserDefaults.standard.object(forKey: "watchDeletedApps") as? Bool ?? true
        openAtLogin = SMAppService.mainApp.status == .enabled
        reloadApps()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Model.shared.runningTick += 1 }
            }
        }
        updateWatcher()
        // The menu bar icon can also change this setting; keep in step with it.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let m = Model.shared
                let v = UserDefaults.standard.object(forKey: "watchDeletedApps") as? Bool ?? true
                if m.watchDeletedApps != v { m.watchDeletedApps = v }
            }
        }
    }

    // MARK: Lists

    var filteredApps: [TargetApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    /// Text that looks like a bundle ID (e.g. com.company.app) - lets you clean up after an app you already deleted.
    var searchAsBundleID: String? {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.split(separator: ".").count >= 3, !q.contains(" "), !q.contains("/") else { return nil }
        return q
    }

    var trashableItems: [FoundItem] { items.filter { $0.kind.trashable } }
    var otherItems: [FoundItem] { items.filter { !$0.kind.trashable } }
    var selectedItems: [FoundItem] { trashableItems.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var orphanGroups: [(id: String, items: [FoundItem])] {
        Dictionary(grouping: trashableItems, by: { $0.group ?? "?" })
            .map { (id: $0.key, items: $0.value) }
            .sorted { $0.id < $1.id }
    }

    func setChecked(_ ids: [String], _ on: Bool) {
        if on { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    // MARK: Running apps

    var runningInstances: [NSRunningApplication] {
        _ = runningTick
        guard let c = current else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID)
    }
    var isRunning: Bool { !runningInstances.isEmpty }

    func quitCurrentApp() {
        let running = runningInstances
        guard !running.isEmpty else { return }
        quitting = true; offerForceQuit = false
        running.forEach { $0.terminate() }
        Task {
            for _ in 0..<10 {   // give it up to 5 seconds (it may ask to save documents)
                try? await Task.sleep(nanoseconds: 500_000_000)
                if runningInstances.isEmpty { break }
            }
            quitting = false
            offerForceQuit = isRunning
        }
    }

    func forceQuitCurrentApp() {
        runningInstances.forEach { $0.forceTerminate() }
        offerForceQuit = false
    }

    // MARK: Selecting and scanning

    func reloadApps() {
        Task.detached(priority: .userInitiated) {
            let found = Scanner.installedApps()
            await MainActor.run {
                // keep any "deleted" entries the user is looking at
                let ghosts = self.apps.filter { $0.url == nil }
                self.apps = ghosts + found.filter { f in !ghosts.contains { $0.bundleID == f.bundleID } }
            }
        }
    }

    func open(_ app: TargetApp) {
        if !apps.contains(where: { $0.id == app.id }) { apps.insert(app, at: 0) }
        if selectedID == app.id { rescan() } else { selectedID = app.id }
    }

    func showOrphans() {
        if selectedID == Self.orphansID { rescan() } else { selectedID = Self.orphansID }
    }

    private func selectionChanged() {
        notice = nil; offerForceQuit = false
        showingOrphans = selectedID == Self.orphansID
        if let id = selectedID, !showingOrphans {
            current = apps.first { $0.id == id }
                ?? (id.hasPrefix("bundle:") ? TargetApp.byBundleID(String(id.dropFirst(7))) : nil)
        } else {
            current = nil
        }
        rescan()
    }

    func rescan() {
        items = []; checked = []
        if showingOrphans {
            scanning = true
            Task.detached(priority: .userInitiated) {
                let found = Scanner.findOrphans()
                await MainActor.run {
                    guard self.showingOrphans else { return }
                    self.items = found
                    self.checked = []          // orphans are never ticked for you
                    self.scanning = false
                }
            }
            return
        }
        guard let app = current, !app.isProtected else { scanning = false; return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = Scanner.scan(app)
            await MainActor.run {
                guard self.current == app, !self.showingOrphans else { return }   // user picked something else
                self.items = found
                // Tick "sure" and "likely" items. "Possible" ones you tick yourself.
                self.checked = Set(found.filter { $0.kind.trashable && $0.confidence >= .likely }.map(\.id))
                self.scanning = false
            }
        }
    }

    // MARK: Moving to the Trash

    func moveToTrash() {
        let chosen = selectedItems
        let safe = chosen.filter(Scanner.isSafeToTrash)     // check again right before acting
        let skipped = chosen.count - safe.count
        guard !safe.isEmpty else { notice = "Nothing could be moved safely, so nothing was changed."; return }
        let removedApp = safe.contains { $0.kind == .app }
        if removedApp, let c = current { trashedByUs.insert(c.bundleID.lowercased()) }

        Task.detached(priority: .userInitiated) {
            for i in safe { Scanner.stopLaunchAgentIfNeeded(i) }   // stop background helpers first
            await MainActor.run {
                NSWorkspace.shared.recycle(safe.map(\.url)) { moved, error in
                    Task { @MainActor in self.finishTrash(moved: moved.count, of: safe.count, skipped: skipped,
                                                          error: error, removedApp: removedApp) }
                }
            }
        }
    }

    private func finishTrash(moved n: Int, of total: Int, skipped: Int, error: Error?, removedApp: Bool) {
        var msg = n < total
            ? "Moved \(n) of \(total) items. Some could not be moved\(error.map { ": " + $0.localizedDescription } ?? ".")"
            : "Moved \(n) item\(n == 1 ? "" : "s") to the Trash. Use Finder's Put Back to undo."
        if skipped > 0 { msg += " Skipped \(skipped) for safety." }
        if removedApp, let c = current {
            // The app is gone: keep it in the list as "deleted" so you can see anything left.
            let gone = TargetApp.byBundleID(c.bundleID, name: c.name)
            apps.removeAll { $0.id == c.id || $0.id == gone.id }
            apps.insert(gone, at: 0)
            selectedID = gone.id      // this rescans
        } else {
            rescan()
        }
        notice = msg
    }

    // MARK: Watching for deleted apps

    private func updateWatcher() {
        if watchDeletedApps, watcher == nil {
            watcher = AppWatcher { app in Task { @MainActor in Model.shared.appWasRemoved(app) } }
        } else if !watchDeletedApps {
            watcher?.stop(); watcher = nil
        }
    }

    /// Called when an app disappears from Applications (e.g. you dragged it to the Trash in Finder).
    func appWasRemoved(_ app: TargetApp) {
        if trashedByUs.remove(app.bundleID.lowercased()) != nil { return }
        guard !app.isProtected else { return }
        let gone = TargetApp.byBundleID(app.bundleID, name: app.name)
        Task.detached(priority: .userInitiated) {
            let found = Scanner.scan(gone, withSizes: false)
            guard found.contains(where: { $0.kind.trashable && $0.confidence >= .likely }) else { return }
            await MainActor.run {
                self.apps.removeAll { $0.id == app.id || $0.id == gone.id }
                self.apps.insert(gone, at: 0)
                if self.selectedID == gone.id { self.rescan() } else { self.selectedID = gone.id }
                self.notice = "\(app.displayName) was deleted. These are the files it left behind."
                self.showWindow()
            }
        }
    }

    func showWindow() {
        openWindowRequest += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Open at login

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        if on, status == .requiresApproval {
            notice = "Please allow Crumbs in System Settings → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
