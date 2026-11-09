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
    @Published var plugins: [TargetApp] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { selectionChanged() } } }
    @Published var current: TargetApp?
    @Published var showingOrphans = false
    @Published var items: [FoundItem] = []
    @Published var checked: Set<String> = []
    @Published var scanning = false
    @Published var search = ""
    @Published var notice: String?
    @Published var homebrewCask: String?
    @Published var dropTargeted = false
    @Published var confirming = false
    @Published var working = false               // moving files / waiting for the password

    // Undo the last "Move to Trash"
    struct Moved: Sendable { let original: URL; let trashed: URL; let admin: Bool }
    @Published var lastMoved: [Moved] = []

    // Quitting a running app
    @Published var runningTick = 0          // bumps when any app starts or quits, so the UI refreshes
    @Published var quitting = false
    @Published var offerForceQuit = false

    // Protected apps (yours to choose, in addition to Apple's)
    @Published var protectedIDs: [String] {
        didSet { UserDefaults.standard.set(protectedIDs, forKey: "protectedBundleIDs") }
    }

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
        protectedIDs = UserDefaults.standard.stringArray(forKey: "protectedBundleIDs") ?? []
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

    private func matches(_ a: TargetApp) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || a.displayName.localizedCaseInsensitiveContains(q) || a.bundleID.localizedCaseInsensitiveContains(q)
    }
    var filteredApps: [TargetApp] { apps.filter(matches) }
    var filteredPlugins: [TargetApp] { plugins.filter(matches) }

    /// Text that looks like a bundle ID (e.g. com.company.app) - lets you clean up after an app you already deleted.
    var searchAsBundleID: String? {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.split(separator: ".").count >= 3, !q.contains(" "), !q.contains("/") else { return nil }
        return q
    }

    var userItems: [FoundItem] { items.filter { !$0.kind.needsAdmin } }
    var adminItems: [FoundItem] { items.filter { $0.kind.needsAdmin } }
    var selectedItems: [FoundItem] { items.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedNeedsPassword: Bool { selectedItems.contains { $0.kind.needsAdmin } }
    var selectedHasUserData: Bool { selectedItems.contains { $0.isUserData } }

    var orphanGroups: [(id: String, items: [FoundItem])] {
        Dictionary(grouping: items, by: { $0.group ?? "?" })
            .map { (id: $0.key, items: $0.value) }
            .sorted { $0.id < $1.id }
    }

    func setChecked(_ ids: [String], _ on: Bool) {
        if on { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    // MARK: Protected apps

    func isUserProtected(_ app: TargetApp) -> Bool { protectedIDs.contains { $0.lowercased() == app.bundleID.lowercased() } }

    func setProtected(_ app: TargetApp, _ on: Bool) {
        protectedIDs.removeAll { $0.lowercased() == app.bundleID.lowercased() }
        if on { protectedIDs.append(app.bundleID) }
        if current?.bundleID == app.bundleID { rescan() }
    }

    // MARK: Running apps

    var runningInstances: [NSRunningApplication] {
        _ = runningTick
        guard let c = current, c.isApp else { return [] }
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
            let plug = Scanner.installedPlugins()
            await MainActor.run {
                // keep any "deleted" entries the user is looking at
                let ghosts = self.apps.filter { $0.url == nil }
                self.apps = ghosts + found.filter { f in !ghosts.contains { $0.bundleID == f.bundleID } }
                self.plugins = plug
            }
        }
    }

    func open(_ app: TargetApp) {
        if !(apps + plugins).contains(where: { $0.id == app.id }) {
            if app.isApp { apps.insert(app, at: 0) } else { plugins.insert(app, at: 0) }
        }
        if selectedID == app.id { rescan() } else { selectedID = app.id }
    }

    func showOrphans() {
        if selectedID == Self.orphansID { rescan() } else { selectedID = Self.orphansID }
    }

    private func selectionChanged() {
        notice = nil; offerForceQuit = false; homebrewCask = nil
        showingOrphans = selectedID == Self.orphansID
        if let id = selectedID, !showingOrphans {
            current = (apps + plugins).first { $0.id == id }
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
            let cask = Scanner.homebrewCask(for: app)
            await MainActor.run {
                guard self.current == app, !self.showingOrphans else { return }   // user picked something else
                self.items = found
                self.homebrewCask = cask
                // Tick "sure" and "likely" items. "Possible" ones you tick yourself.
                self.checked = Set(found.filter { $0.confidence >= .likely }.map(\.id))
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
        let user = safe.filter { !$0.kind.needsAdmin }
        let admin = safe.filter { $0.kind.needsAdmin }
        let removedApp = current.map { c in safe.contains { $0.url == c.url } } ?? false
        if removedApp, let c = current { trashedByUs.insert(c.bundleID.lowercased()) }
        working = true

        Task.detached(priority: .userInitiated) {
            for i in user { Scanner.stopLaunchAgentIfNeeded(i) }       // stop background helpers first
            let adminResult = Admin.moveToHolding(admin)                 // asks for your password (if needed)
            var origin: [URL: URL] = [:]                                 // held file -> where it came from
            for h in adminResult.held { origin[h.now] = h.original }
            let urls = user.map(\.url) + adminResult.held.map(\.now)
            let originMap = origin
            await MainActor.run {
                guard !urls.isEmpty else {
                    self.working = false
                    self.notice = adminResult.cancelled ? "Cancelled. Nothing was moved." : "Nothing could be moved."
                    return
                }
                NSWorkspace.shared.recycle(urls) { newURLs, error in
                    Task { @MainActor in
                        self.lastMoved = newURLs.map { src, dst in
                            Moved(original: originMap[src] ?? src, trashed: dst, admin: originMap[src] != nil)
                        }
                        Admin.cleanHolding()
                        self.finishTrash(moved: newURLs.count, of: safe.count, skipped: skipped,
                                         adminCancelled: adminResult.cancelled, error: error, removedApp: removedApp)
                    }
                }
            }
        }
    }

    private func finishTrash(moved n: Int, of total: Int, skipped: Int, adminCancelled: Bool, error: Error?, removedApp: Bool) {
        working = false
        var msg = n < total
            ? "Moved \(n) of \(total) items."
            : "Moved \(n) item\(n == 1 ? "" : "s") to the Trash."
        if adminCancelled { msg += " System files were skipped (no password)." }
        else if n < total, let error { msg += " " + error.localizedDescription }
        if skipped > 0 { msg += " Skipped \(skipped) for safety." }
        if removedApp, let c = current, n > 0 {
            // The app is gone: keep it in the list as "deleted" so you can see anything left.
            let gone = TargetApp.byBundleID(c.bundleID, name: c.name)
            apps.removeAll { $0.id == c.id || $0.id == gone.id }
            plugins.removeAll { $0.id == c.id }
            apps.insert(gone, at: 0)
            selectedID = gone.id      // this rescans
        } else {
            rescan()
        }
        notice = msg
    }

    /// Puts the last moved items back where they were.
    func undoLastMove() {
        let moves = lastMoved
        guard !moves.isEmpty else { return }
        working = true
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var restored = 0, failed = 0
            var adminMoves: [Moved] = []
            for m in moves {
                if m.admin { adminMoves.append(m); continue }
                do {
                    try fm.createDirectory(at: m.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: m.trashed, to: m.original)
                    restored += 1
                } catch { failed += 1 }
            }
            if !adminMoves.isEmpty {
                // System files need your password to go back, and get their system owner back.
                let ok = Admin.restore(adminMoves.map { ($0.trashed, $0.original) })
                restored += ok; failed += adminMoves.count - ok
            }
            let (restoredCount, failedCount) = (restored, failed)
            await MainActor.run {
                self.working = false
                self.lastMoved = []
                self.reloadApps()
                if let c = self.current, c.url == nil,
                   let back = moves.lazy.compactMap({ TargetApp.load($0.original) }).first {
                    self.apps.removeAll { $0.id == c.id }
                    self.open(back)
                } else {
                    self.rescan()
                }
                self.notice = failedCount == 0 ? "Put back \(restoredCount) item\(restoredCount == 1 ? "" : "s")."
                                          : "Put back \(restoredCount). \(failedCount) could not be put back (they're still in the Trash)."
            }
        }
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
            guard found.contains(where: { $0.confidence >= .likely }) else { return }
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
        NSApp.setActivationPolicy(.regular)       // bring back the Dock icon
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
