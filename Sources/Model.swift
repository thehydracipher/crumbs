// Model.swift - the app's state and actions.
// Part of Crumbs. MIT License.

import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    static let orphansID = "special:orphans"
    static let homeID = "special:home"

    // What's on screen
    @Published var apps: [TargetApp] = []
    @Published var plugins: [TargetApp] = []
    @Published var selectedID: String? = Model.homeID { didSet { if selectedID != oldValue { selectionChanged() } } }
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
    private var scanNumber = 0                   // only the newest scan may update the screen
    @Published var needsAppManagement = false    // macOS blocked moving an app: show how to allow it

    // Undo the last "Move to Trash"
    struct Moved: Sendable, Codable {
        let original: URL; let trashed: URL
        let admin: Admin.Held?          // set for system files (owner + fingerprint for a safe Undo)
    }
    /// Kept on disk too, so Undo still works after Crumbs restarts (e.g. after you grant Full Disk Access).
    @Published var lastMoved: [Moved] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(lastMoved), forKey: "lastMoved") }
    }

    // Full Disk Access (needed to see every Library folder and to move things back out of the Trash)
    @Published var hasFullDiskAccess = Scanner.hasFullDiskAccess()

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

    // Updates
    @Published var update: Release?                 // a newer version on GitHub
    @Published var updateStatus: String?            // "Checking…", "Downloading…"
    @Published var updateHidden = false             // you clicked "Later"
    @Published var autoUpdates: Bool { didSet { UserDefaults.standard.set(autoUpdates, forKey: "autoCheckUpdates") } }
    private var watcher: AppWatcher?
    private var trashedByUs: Set<String> = []   // bundle IDs we removed ourselves (don't pop up for those)

    private init() {
        Model.moveOldSettings()                 // quick: settings only
        watchDeletedApps = UserDefaults.standard.object(forKey: "watchDeletedApps") as? Bool ?? true
        protectedIDs = UserDefaults.standard.stringArray(forKey: "protectedBundleIDs") ?? []
        autoUpdates = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
        openAtLogin = SMAppService.mainApp.status == .enabled
        if let data = UserDefaults.standard.data(forKey: "lastMoved"),
           let saved = try? JSONDecoder().decode([Moved].self, from: data) {
            lastMoved = saved.filter { FileManager.default.fileExists(atPath: $0.trashed.path) || !Scanner.hasFullDiskAccess() }
        }
        // Re-check Full Disk Access whenever you come back to Crumbs (e.g. from System Settings).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let m = Model.shared
                let now = Scanner.hasFullDiskAccess()
                if now != m.hasFullDiskAccess { m.hasFullDiskAccess = now; m.rescan() }
            }
        }
        reloadApps()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Model.shared.runningTick += 1 }
            }
        }
        updateWatcher()
        startAutomaticUpdateChecks()
        // While Crumbs lacks Full Disk Access, look again every few seconds, so the banner
        // disappears by itself as soon as you turn it on.
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !hasFullDiskAccess, Scanner.hasFullDiskAccess() { hasFullDiskAccess = true; rescan() }
            }
        }
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
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + max(0, $1.size) } }
    var sizesPending: Bool { items.contains { $0.size < 0 } }
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
                // Keep a "deleted" entry only while you're looking at it.
                let ghosts = self.apps.filter { $0.url == nil && $0.id == self.selectedID }
                self.apps = ghosts + found.filter { f in !ghosts.contains { $0.bundleID == f.bundleID } }
                self.plugins = plug
            }
        }
    }

    /// The Refresh button: forget what was remembered, reload the app list, and look again.
    func refresh() {
        Scanner.clearCaches()
        reloadApps()
        if selectedID != nil { rescan() }
    }

    /// Back to the welcome screen (Home in the sidebar, Esc, and whenever the window opens).
    func goHome() {
        selectedID = Model.homeID
        search = ""
    }

    /// Crumbs used to be called io.github.rus024.crumbs inside. Move its settings to the new name once,
    /// and send Crumbs' own old folders (settings file, caches, window state) to the Trash.
    private static func moveOldSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "movedFromOldName") else { return }
        for old in Scanner.oldBundleIDs {
            for (k, v) in d.persistentDomain(forName: old) ?? [:] where d.object(forKey: k) == nil { d.set(v, forKey: k) }
            d.removePersistentDomain(forName: old)
        }
        d.set(true, forKey: "movedFromOldName")
        // The old folders go to the Trash in the background, so starting Crumbs is never held up.
        Task.detached(priority: .utility) {
            for old in Scanner.oldBundleIDs {
                for item in Scanner.scan(.byBundleID(old), withSizes: false)
                where item.kind == .file && item.confidence >= .likely && Scanner.isSafeToTrash(item) {
                    try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
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
        notice = nil; offerForceQuit = false; homebrewCask = nil; needsAppManagement = false
        showingOrphans = selectedID == Self.orphansID
        if let id = selectedID, !showingOrphans, id != Self.homeID {
            current = (apps + plugins).first { $0.id == id }
                ?? (id.hasPrefix("bundle:") ? TargetApp.byBundleID(String(id.dropFirst(7))) : nil)
        } else {
            current = nil
        }
        rescan()
    }

    func rescan() {
        items = []; checked = []
        scanNumber += 1
        let myScan = scanNumber
        if showingOrphans {
            scanning = true
            Task.detached(priority: .userInitiated) {
                let found = Scanner.findOrphans(withSizes: false)
                await MainActor.run {
                    guard self.showingOrphans, self.scanNumber == myScan else { return }
                    self.items = found
                    self.checked = []          // orphans are never ticked for you
                    self.scanning = false
                }
                await self.fillSizes(found) { self.showingOrphans && self.scanNumber == myScan }
            }
            return
        }
        guard let app = current, !app.isProtected else { scanning = false; return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            // 1. Show the list straight away ...
            let found = Scanner.scan(app, withSizes: false)
            await MainActor.run {
                // user picked something else, or a newer scan (e.g. Refresh) started meanwhile
                guard self.current == app, !self.showingOrphans, self.scanNumber == myScan else { return }
                // A deleted app with nothing left: remove it from the list and go back to the welcome screen.
                if app.url == nil, found.isEmpty {
                    let msg = self.notice.map { $0 + " " } ?? ""
                    self.apps.removeAll { $0.id == app.id }
                    self.selectedID = Model.homeID
                    self.scanning = false
                    self.notice = msg + "\(app.displayName) is gone. Nothing left behind."
                    return
                }
                self.items = found
                // Tick "sure" and "likely" items. "Possible" ones you tick yourself.
                self.checked = Set(found.filter { $0.confidence >= .likely }.map(\.id))
                self.scanning = false
            }
            // 2. ... then measure sizes (in parallel) and check Homebrew, filling them in as they're ready.
            async let cask = Scanner.homebrewCask(for: app)
            await self.fillSizes(found) { self.current == app && !self.showingOrphans && self.scanNumber == myScan }
            let c = await cask
            await MainActor.run { if self.current == app, self.scanNumber == myScan { self.homebrewCask = c } }
        }
    }

    /// Measures sizes off the main thread and updates the list, if it's still showing the same thing.
    nonisolated private func fillSizes(_ found: [FoundItem], stillShowing: @escaping @MainActor () -> Bool) async {
        let sized = Scanner.withSizes(found)
        let bySize = Dictionary(uniqueKeysWithValues: sized.map { ($0.id, $0.size) })
        await MainActor.run {
            guard stillShowing() else { return }
            self.items = self.items.map { var i = $0; if let sz = bySize[i.id] { i.size = sz }; return i }
        }
    }

    // MARK: Moving to the Trash

    func moveToTrash() {
        let chosen = Scanner.withoutNested(selectedItems)
        let safe = chosen.filter(Scanner.isSafeToTrash)     // check again right before acting
        let skipped = chosen.count - safe.count
        guard !safe.isEmpty else { notice = "Nothing could be moved safely, so nothing was changed."; return }
        let user = safe.filter { !$0.kind.needsAdmin }
        let admin = safe.filter { $0.kind.needsAdmin }
        // Is the app itself going (directly, or inside a wrapper folder that is going)?
        let appURL = current?.url.flatMap { u in
            safe.contains { $0.url == u || u.path.hasPrefix($0.url.path + "/") } ? u : nil
        }
        let appID = current?.bundleID.lowercased()
        if appURL != nil, let appID { trashedByUs.insert(appID) }
        working = true

        Task.detached(priority: .userInitiated) {
            for i in user { Scanner.stopLaunchAgentIfNeeded(i) }       // stop background helpers first
            let adminResult = Admin.moveToHolding(admin)                 // asks for your password (if needed)
            var held: [URL: Admin.Held] = [:]                            // holding place -> details
            for h in adminResult.held { held[h.now] = h }
            let urls = user.map(\.url) + adminResult.held.map(\.now)
            let heldMap = held
            await MainActor.run {
                guard !urls.isEmpty else {
                    if let appID { self.trashedByUs.remove(appID) }
                    self.working = false
                    self.notice = adminResult.cancelled ? "Cancelled. Nothing was moved." : "Nothing could be moved."
                    return
                }
                NSWorkspace.shared.recycle(urls) { newURLs, error in
                    Task { @MainActor in
                        self.lastMoved = newURLs.map { src, dst in
                            Moved(original: heldMap[src]?.original ?? src, trashed: dst, admin: heldMap[src])
                        }
                        Admin.cleanHolding(adminResult.held)
                        let appGone = appURL.map { u in
                            self.lastMoved.contains { $0.original == u || u.path.hasPrefix($0.original.path + "/") }
                        } ?? false
                        if !appGone, let appID { self.trashedByUs.remove(appID) }
                        self.finishTrash(moved: newURLs.count, of: safe.count, skipped: skipped,
                                         adminCancelled: adminResult.cancelled, adminFailed: adminResult.failed,
                                         error: error, appGone: appGone, appIntended: appURL != nil)
                    }
                }
            }
        }
    }

    private func finishTrash(moved n: Int, of total: Int, skipped: Int, adminCancelled: Bool, adminFailed: Int,
                             error: Error?, appGone: Bool, appIntended: Bool) {
        working = false
        var msg = n < total
            ? "Moved \(n) of \(total) items."
            : "Moved \(n) item\(n == 1 ? "" : "s") to the Trash."
        if adminCancelled { msg += " System files were skipped (no password)." }
        else if adminFailed > 0 { msg += " \(adminFailed) system file(s) could not be moved." }
        else if n < total, let error { msg += " " + error.localizedDescription }
        if skipped > 0 { msg += " Skipped \(skipped) for safety." }
        if appIntended && !appGone && !adminCancelled {
            msg = "macOS blocked moving the app. Allow Crumbs under App Management, then try again. " + msg
            needsAppManagement = true
        }
        if appGone, let c = current {
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
        guard !moves.isEmpty, !working else { return }
        hasFullDiskAccess = Scanner.hasFullDiskAccess()
        guard hasFullDiskAccess else {
            notice = "To put files back, Crumbs needs Full Disk Access (macOS protects the Trash). Turn it on, reopen Crumbs, then Undo. Your Undo is saved."
            return
        }
        working = true
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var restored = 0, failed = 0, changed = 0
            var adminMoves: [Moved] = []
            for m in moves {
                if m.admin != nil { adminMoves.append(m); continue }
                do {
                    try fm.createDirectory(at: m.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: m.trashed, to: m.original)
                    restored += 1
                } catch { failed += 1 }
            }
            if !adminMoves.isEmpty {
                // System files: one password prompt, fingerprint-checked, original owner restored.
                let r = Admin.restore(adminMoves.compactMap { m in
                    m.admin.map { (trashed: m.trashed, original: m.original, owner: $0.owner, fingerprint: $0.fingerprint, realParent: $0.realParent) }
                })
                restored += r.ok; changed += r.changed; failed += adminMoves.count - r.ok - r.changed
            }
            let (okCount, failCount, changedCount) = (restored, failed, changed)
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
                var msg = "Put back \(okCount) item\(okCount == 1 ? "" : "s")."
                if changedCount > 0 { msg += " \(changedCount) changed while in the Trash, so it was NOT put back (for safety)." }
                if failCount > 0 { msg += " \(failCount) could not be put back (still in the Trash)." }
                self.notice = msg
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

    func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }

    func openAppManagementSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") { NSWorkspace.shared.open(u) }
    }

    // MARK: Updates

    /// Once a day (while Crumbs is open), quietly look for a newer version.
    private func startAutomaticUpdateChecks() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)        // let Crumbs start first
            while true {
                let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
                if autoUpdates, Date().timeIntervalSince(last) > 24 * 3600 { await checkForUpdates(userAsked: false) }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)   // look again in an hour
            }
        }
    }

    func checkForUpdates(userAsked: Bool) async {
        guard updateStatus == nil else { return }
        if userAsked { updateStatus = "Checking for updates…" }
        defer { if updateStatus == "Checking for updates…" { updateStatus = nil } }
        do {
            let r = try await Updater.latest()
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            if Updater.isNewer(r.version, than: Updater.currentVersion) {
                update = r; updateHidden = false
                if userAsked { showWindow() }
            } else if userAsked {
                alert("You're up to date.", "Crumbs \(Updater.currentVersion) is the newest version.")
            }
        } catch {
            if userAsked { alert("Couldn't check for updates.", error.localizedDescription) }
        }
    }

    func installUpdate() async {
        guard let r = update, updateStatus == nil else { return }
        updateStatus = "Downloading Crumbs \(r.version)…"
        do {
            let app = try await Updater.download(r)
            updateStatus = "Installing…"
            try Updater.install(app)
            NSApp.terminate(nil)                    // the helper swaps the app and opens the new one
        } catch {
            updateStatus = nil
            if alert("The update didn't install.", error.localizedDescription + "\n\nYou can download it from GitHub instead.",
                     buttons: ["Open GitHub", "OK"]) == .alertFirstButtonReturn {
                NSWorkspace.shared.open(r.page)
            }
        }
    }

    @discardableResult
    func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }

    // MARK: Uninstall Crumbs itself

    /// Removes Crumbs cleanly: its login item, its own settings and caches, and the app. Then quits.
    func uninstallCrumbs() {
        guard alert("Uninstall Crumbs?",
                    "Crumbs and its settings go to the Trash. You can put them back from the Trash until you empty it.",
                    buttons: ["Uninstall", "Cancel"]) == .alertFirstButtonReturn else { return }
        try? SMAppService.mainApp.unregister()
        watcher?.stop()
        func ownFiles(_ t: TargetApp) -> [URL] {
            Scanner.scan(t, withSizes: false)
                .filter { $0.kind == .file && $0.confidence >= .likely && Scanner.isSafeToTrash($0) }.map(\.url)
        }
        var urls = ownFiles(.byBundleID(Bundle.main.bundleIdentifier ?? Scanner.myBundleID, name: "Crumbs"))
        for old in Scanner.oldBundleIDs { urls += ownFiles(.byBundleID(old)) }
        urls.append(Bundle.main.bundleURL)
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? Scanner.myBundleID)
        NSWorkspace.shared.recycle(urls) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
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
