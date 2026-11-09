// Scanner.swift - finds the files an app leaves behind.
// It looks in known places (no full-disk walk), so it is fast.
// Part of Crumbs. MIT License.

import Foundation
import AppKit
import Security

// MARK: - Types

struct TargetApp: Identifiable, Hashable, Sendable {
    var url: URL?          // nil when the app is already deleted
    var bundleID: String
    var name: String
    var version: String?
    var displayName2: String? = nil     // CFBundleDisplayName, if different
    var executable: String? = nil       // CFBundleExecutable (crash reports use it)

    var id: String { url?.path ?? "bundle:" + bundleID }
    var displayName: String { name.isEmpty ? bundleID : name }
    var isApp: Bool { url == nil || url!.pathExtension.lowercased() == "app" }

    /// What kind of thing this is, e.g. "Screen Saver".
    var typeLabel: String {
        guard let ext = url?.pathExtension.lowercased() else { return "App" }
        return Scanner.bundleTypes[ext] ?? "Plug-in"
    }

    /// Built-in Apple apps, macOS-locked (SIP) apps and apps you protected yourself are never touched.
    var isProtected: Bool { protectionReason != nil }
    var protectionReason: String? {
        if bundleID.lowercased().hasPrefix("com.apple.") || (url?.path.hasPrefix("/System/") ?? false) {
            return "This is a built-in Apple app."
        }
        if isCrumbs { return "This is Crumbs." }
        if let u = url, Scanner.isSIPLocked(u) { return "macOS protects this app (System Integrity Protection)." }
        if Scanner.userProtectedIDs().contains(bundleID.lowercased()) { return "You protected this app." }
        return nil
    }
    var isUserProtected: Bool { Scanner.userProtectedIDs().contains(bundleID.lowercased()) }
    var isCrumbs: Bool {
        let b = bundleID.lowercased()
        return b == Scanner.myBundleID || Scanner.oldBundleIDs.contains(b) || b == Bundle.main.bundleIdentifier?.lowercased()
    }

    static func load(_ url: URL) -> TargetApp? {
        guard Scanner.bundleTypes[url.pathExtension.lowercased()] != nil,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                ?? NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
                ?? NSDictionary(contentsOf: url.appendingPathComponent("WrappedBundle/Info.plist")),   // iPhone/iPad apps
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        let name = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        func str(_ k: String) -> String? { (info[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return TargetApp(url: url, bundleID: id, name: name, version: str("CFBundleShortVersionString"),
                         displayName2: str("CFBundleDisplayName").flatMap { $0.lowercased() == name.lowercased() ? nil : $0 },
                         executable: str("CFBundleExecutable"))
    }

    /// For an app that is already gone: search by its bundle ID (and name, if we know it).
    static func byBundleID(_ id: String, name: String = "") -> TargetApp {
        TargetApp(url: nil, bundleID: id, name: name, version: nil)
    }
}

enum ItemKind: Sendable {
    case app       // the app or plug-in itself (yours to move)
    case file      // a leftover you own
    case admin     // a system file - asks for your password
    case receipt   // an installer receipt - asks for your password

    var needsAdmin: Bool { self == .admin || self == .receipt }
}

/// How sure we are that a file belongs to the app.
enum Confidence: Int, Comparable, Sendable {
    case possible = 0   // looks similar (e.g. "Name 2", "NameBeta"). Never ticked by default.
    case likely = 1     // has exactly the app's name
    case sure = 2       // matches the bundle ID, or the app's own signature says so

    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Possible", "Likely", "Sure"][rawValue] }
}

struct FoundItem: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: ItemKind
    var confidence: Confidence
    var size: Int64 = -1         // -1 until measured
    var group: String? = nil    // orphan finder: the bundle ID this file belongs to
    var id: String { url.path }

    /// Folders that usually hold your own data (documents, settings, history), not just caches.
    var isUserData: Bool {
        let p = url.path
        return ["/Library/Containers/", "/Library/Group Containers/", "/Library/Application Support/"]
            .contains { p.contains($0) } && !p.contains("/Caches/") && !p.contains("/CrashReporter/")
            && !p.contains("/com.apple.sharedfilelist/")
    }
}

// MARK: - Scanner

enum Scanner {
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var library: URL { home.appendingPathComponent("Library") }
    static let systemLibrary = URL(fileURLWithPath: "/Library")

    /// Bundle types Crumbs can remove, and what to call them.
    static let bundleTypes: [String: String] = [
        "app": "App", "prefpane": "Preference Pane", "qlgenerator": "Quick Look Plug-in",
        "appex": "App Extension", "saver": "Screen Saver", "mdimporter": "Spotlight Plug-in",
        "wdgt": "Widget", "component": "Audio Plug-in", "vst": "Audio Plug-in", "vst3": "Audio Plug-in",
        "driver": "Audio Driver", "plugin": "Plug-in", "bundle": "Plug-in", "colorpicker": "Color Picker",
        "service": "Service", "mailbundle": "Mail Plug-in", "workflow": "Automator Workflow",
        "kext": "Kernel Extension", "fs": "File System", "osax": "Scripting Addition", "clap": "Audio Plug-in",
        "action": "Automator Action", "xpc": "XPC Service", "systemextension": "System Extension",
    ]

    /// Library folders where plug-ins live (in ~/Library and /Library).
    static let pluginFolders = [
        "PreferencePanes", "QuickLook", "Screen Savers", "Internet Plug-Ins", "Spotlight", "Services",
        "Mail/Bundles", "Contextual Menu Items", "Input Methods", "ColorPickers", "Widgets",
        "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/HAL",
        "Address Book Plug-Ins", "PDF Services", "Compositions", "Components",
        "Audio/Plug-Ins/MAS", "Audio/Plug-Ins/CLAP", "CoreMediaIO/Plug-Ins/DAL", "Filesystems", "Extensions",
        "ScriptingAdditions", "StartupItems", "QuickTime", "CoreImage", "Automator",
    ]

    /// Extra Library folders that are searched by name or bundle ID (AppCleaner checks these too).
    static let extraFolders = pluginFolders + [
        "Autosave Information", "Audio/Presets", "Scripts/Applications", "Workflows/Applications",
        "Dictionaries", "Spelling", "Keyboard Layouts", "Colors", "FontCollections",
    ]

    /// Names too vague to match safely. For these we only match by bundle ID.
    static let genericNames: Set<String> = [
        "app", "apps", "helper", "update", "updater", "data", "cache", "caches", "logs",
        "tmp", "temp", "google", "microsoft", "adobe", "apple", "mozilla", "default",
        "mail", "notes", "code", "sync", "music", "photos", "preview", "settings",
        "common", "shared", "support", "launcher", "installer", "uninstaller", "agent", "service", "services",
        "client", "server", "studio", "player", "editor", "viewer", "manager", "assistant", "tools", "utilities",
        "framework", "frameworks", "plugins", "plug-ins", "extensions", "documents", "downloads", "desktop",
        "library", "system", "users", "public", "private", "browser", "crash", "crashes", "reports", "backup",
    ]

    /// Standard folders inside ~/Library and /Library (from AppCleaner's own list). A folder directly in
    /// Library that is NOT one of these, and is named after the app, belongs to the app.
    static let standardLibraryFolders: Set<String> = [
        "accounts", "application scripts", "application support", "assistants", "audio", "autosave information",
        "biome", "caches", "calendars", "callservices", "colorpickers", "colors", "colorsync", "components",
        "compositions", "containers", "contextual menu items", "cookies", "coremediaio", "daemon containers",
        "desktop pictures", "developer", "dictionaries", "directoryservices", "documentation", "extensions",
        "favorites", "filesystems", "fontcollections", "fonts", "frameworks", "gpubundles", "graphics",
        "group containers", "httpstorages", "identityservices", "image capture", "input methods",
        "internet plug-ins", "java", "kernelcollections", "keyboard layouts", "keychains", "languagemodeling",
        "launchagents", "launchdaemons", "logs", "mail", "messages", "metadata", "mobile documents",
        "mobiledevice", "modem scripts", "opendirectory", "pdf services", "personalizationportrait", "perl",
        "photos", "preferencepanes", "preferences", "printers", "privilegedhelpertools", "pubsub", "python",
        "quicklook", "quicktime", "receipts", "recent documents", "ruby", "safari", "sandbox",
        "saved application state", "screen savers", "scriptingadditions", "scripts", "security", "services",
        "sharing", "shortcuts", "sounds", "speech", "spelling", "spotlight", "startupitems", "staged extensions",
        "suggestions", "syncedpreferences", "systemextensions", "systemmigration", "trial", "updates",
        "user pictures", "video", "voices", "webkit", "widgets", "workflows", "cloudstorage", "finance",
        "homekit", "duetexpertcenter", "apple", "assets", "intelligence platform", "studentkit",
    ]

    /// IDs of helpers INSIDE an app (login items, XPC services, extensions, helper apps), plus the root
    /// helper tools it declares in Info.plist (SMPrivilegedExecutables). AppCleaner searches these too.
    private static let cacheLock = NSLock()
    private static var nestedCache: [String: (Date, [String])] = [:]
    private static var appsCache: (Date, [TargetApp])?

    /// Cached: only re-read when the app's Contents folder changes (e.g. after an update).
    static func nestedIDs(of app: URL) -> [String] {
        let contents = app.appendingPathComponent("Contents").path
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: contents))?[.modificationDate] as? Date) ?? .distantPast
        cacheLock.lock()
        if let hit = nestedCache[app.path], hit.0 == mtime { cacheLock.unlock(); return hit.1 }
        cacheLock.unlock()
        let ids = readNestedIDs(of: app)
        cacheLock.lock(); nestedCache[app.path] = (mtime, ids); cacheLock.unlock()
        return ids
    }

    private static var dirCache: [String: (Int, Int, [String])] = [:]

    /// A folder's contents, remembered until the folder changes (macOS updates a folder's timestamp
    /// whenever something is added, removed or renamed in it, so this can never be out of date).
    static func listDir(_ path: String) -> [String] {
        var st = stat()
        guard stat(path, &st) == 0 else { return [] }
        let (sec, nsec) = (Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec))
        cacheLock.lock()
        if let hit = dirCache[path], hit.0 == sec, hit.1 == nsec { cacheLock.unlock(); return hit.2 }
        cacheLock.unlock()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        cacheLock.lock(); dirCache[path] = (sec, nsec, names); cacheLock.unlock()
        return names
    }

    /// Lists many folders at once, in parallel (fills the cache for listDir).
    static func prefetch(_ paths: [String]) {
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in _ = listDir(paths[i]) }
    }

    /// Forget everything remembered (used by the Refresh button).
    static func clearCaches() {
        cacheLock.lock()
        dirCache = [:]; nestedCache = [:]; groupsCache = [:]; appsCache = nil
        cacheLock.unlock()
    }

    /// installedApps(), reused for a few seconds (a scan needs it to spot shared helpers).
    static func installedAppsRecent() -> [TargetApp] {
        cacheLock.lock()
        if let c = appsCache, Date().timeIntervalSince(c.0) < 5 { cacheLock.unlock(); return c.1 }
        cacheLock.unlock()
        let apps = installedApps()
        cacheLock.lock(); appsCache = (Date(), apps); cacheLock.unlock()
        return apps
    }

    private static func readNestedIDs(of app: URL) -> [String] {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        var ids: [String] = []
        for sub in ["Library/LoginItems", "Library/LaunchServices", "Library/SystemExtensions", "XPCServices",
                    "PlugIns", "Helpers", "Frameworks"] {
            let dir = contents.appendingPathComponent(sub)
            for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                if let id = bundleID(of: dir.appendingPathComponent(n)) { ids.append(id) }
                else if sub == "Library/LaunchServices" { ids.append(n) }   // helper tools are named by their ID
            }
        }
        if let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
           let tools = info["SMPrivilegedExecutables"] as? [String: Any] { ids += tools.keys }
        return Array(Set(ids.map { $0.lowercased() })).filter {
            looksLikeBundleID($0) && !$0.hasPrefix("com.apple.") && !$0.hasPrefix("org.sparkle-project")
        }.sorted()
    }

    /// "Bartender 5" -> "Bartender" (same as AppCleaner's stringByStrippingTrailingDigits)
    static func stripTrailingDigits(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\d+$"#, with: "", options: .regularExpression)
    }

    /// Apple's own data folders inside Application Support / Caches / Logs. Crumbs never looks inside them:
    /// they never hold other apps' files, and opening some makes macOS ask for permissions Crumbs doesn't need.
    static func isAppleData(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.hasPrefix("com.apple") || l.hasPrefix("group.com.apple") || appleDataFolders.contains(l)
    }
    static let appleDataFolders: Set<String> = [
        "apple", "addressbook", "callhistorydb", "callhistorytransactions", "mobilesync", "knowledge",
        "fileprovider", "facetime", "differentialprivacy", "clouddocs", "cloudkit", "familycircle",
        "familycircled", "icloud", "music", "tv", "photos", "photoslibrary", "safari", "mail", "messages",
        "calendars", "contacts", "reminders", "notes", "stocks", "homekit", "accounts", "biome", "crashreporter",
        "syncservices", "animoji", "dock", "dictionaries", "spotlight", "sharedfilelist", "quicklook",
        "geoservices", "maps", "weather", "news", "podcasts", "books", "ibooks", "voicememos", "shortcuts",
        "freeform", "journal", "passwords", "keychains", "networkserviceproxy", "siri", "assistant",
    ]

    /// Parts of ~/Library that hold precious things (passwords, iCloud Drive, mail, messages...).
    /// Crumbs never moves anything inside them.
    static let neverTouch: Set<String> = [
        "keychains", "mobile documents", "cloudstorage", "mail", "messages", "accounts", "safari",
        "calendars", "photos", "identityservices", "biome", "sharing", "suggestions", "personalizationportrait",
        "finance", "homekit", "metadata", "trial", "daemon containers", "fonts",
    ]

    /// Folders for command-line tools; apps sometimes add links here pointing into the app.
    static var commandLineFolders: [String] {
        ["/usr/local/bin", "/opt/homebrew/bin", home.appendingPathComponent(".local/bin").path, home.appendingPathComponent("bin").path]
    }

    /// Can you (without a password) move this item? Root-owned items need the password route.
    /// Judged from owner and permission bits only. (macOS's separate "App Management" permission
    /// is handled when moving: Crumbs then tells you how to allow it.)
    static func youCanMove(_ u: URL) -> Bool {
        var ps = stat(), st = stat()
        guard lstat(u.deletingLastPathComponent().path, &ps) == 0, lstat(u.path, &st) == 0 else { return false }
        if (ps.st_mode & S_ISVTX) != 0, st.st_uid != getuid() { return false }      // sticky folder: must be yours
        guard canWrite(ps) else { return false }
        if (st.st_mode & S_IFMT) == S_IFDIR, !canWrite(st) { return false }         // moving a folder needs write access to it
        return true
    }

    private static func canWrite(_ st: stat) -> Bool {
        if getuid() == 0 { return true }
        if st.st_uid == getuid() { return (st.st_mode & S_IWUSR) != 0 }
        var groups = [gid_t](repeating: 0, count: 64)
        let n = getgroups(Int32(groups.count), &groups)
        if (n > 0 && groups.prefix(Int(n)).contains(st.st_gid)) || st.st_gid == getgid() { return (st.st_mode & S_IWGRP) != 0 }
        return (st.st_mode & S_IWOTH) != 0
    }

    static let myBundleID = "io.github.thehydracipher.crumbs"
    /// Crumbs' ID before the rename (versions up to 1.3). Treated as Crumbs itself.
    static let oldBundleIDs = ["io.github.rus024.crumbs"]

    /// Does Crumbs have Full Disk Access?
    /// Tries to list a few folders macOS always protects. (Opening the privacy database, the trick
    /// AppCleaner uses, no longer tells you anything on newer macOS.)
    /// Without access, macOS hides some Library folders and blocks moving things back out of the Trash.
    static func hasFullDiskAccess() -> Bool {
        for rel in ["Autosave Information", "Safari", "Application Support/CallHistoryDB",
                    "Application Support/MobileSync", "Mail", "Messages"] {
            let path = library.appendingPathComponent(rel).path
            var st = stat()
            guard stat(path, &st) == 0 else { continue }          // not on this Mac: try the next one
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        return true   // none of them exist: nothing to tell us otherwise
    }

    /// Reads a bundle's ID from its Info.plist (for plug-ins and kernel extensions).
    static func bundleID(of u: URL) -> String? {
        guard bundleTypes[u.pathExtension.lowercased()] != nil else { return nil }
        for rel in ["Contents/Info.plist", "Info.plist"] {
            if let d = NSDictionary(contentsOf: u.appendingPathComponent(rel)), let id = d["CFBundleIdentifier"] as? String { return id }
        }
        return nil
    }

    // MARK: Protection

    static func userProtectedIDs() -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: "protectedBundleIDs") ?? []).map { $0.lowercased() })
    }

    /// Files macOS has locked with System Integrity Protection (the "restricted" flag).
    static func isSIPLocked(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(SF_RESTRICTED)) != 0
    }

    // MARK: Finding installed apps and plug-ins

    static func installedApps() -> [TargetApp] {
        let fm = FileManager.default
        // (folder, depth). Depth 0 folders also get one level of sub-folders, like /Applications/Utilities.
        var dirs: [(URL, Int)] = [(URL(fileURLWithPath: "/Applications"), 0), (home.appendingPathComponent("Applications"), 0)]
        var apps: [TargetApp] = []
        var seen = Set<String>()
        while !dirs.isEmpty {
            let (dir, depth) = dirs.removeFirst()
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names where !n.hasPrefix(".") {
                let u = dir.appendingPathComponent(n)
                if n.lowercased().hasSuffix(".app") {
                    if let a = TargetApp.load(u), seen.insert(a.id).inserted { apps.append(a) }
                } else if depth == 0, isDirectory(u) {
                    dirs.append((u, 1))
                }
            }
        }
        return sorted(apps)
    }

    /// Preference panes, screen savers, Quick Look and audio plug-ins, etc. Apple's own are left out.
    static func installedPlugins() -> [TargetApp] {
        var out: [TargetApp] = []
        for root in [library, systemLibrary] {
            for d in pluginFolders {
                let dir = root.appendingPathComponent(d)
                for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    let ext = (n as NSString).pathExtension.lowercased()
                    guard ext != "app", bundleTypes[ext] != nil,
                          let t = TargetApp.load(dir.appendingPathComponent(n)),
                          !t.bundleID.lowercased().hasPrefix("com.apple.") else { continue }
                    out.append(t)
                }
            }
        }
        return sorted(out)
    }

    private static func sorted(_ a: [TargetApp]) -> [TargetApp] {
        a.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Is an app with this bundle ID installed anywhere (not counting the Trash)?
    static func isInstalledAnywhere(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { u in
            !u.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: u.path)
        }
    }

    /// If Homebrew installed this app, returns the cask name (so you can also run `brew uninstall --cask`).
    static func homebrewCask(for app: TargetApp) -> String? {
        guard let file = app.url?.lastPathComponent else { return nil }
        let fm = FileManager.default
        for room in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            for token in (try? fm.contentsOfDirectory(atPath: room)) ?? [] where !token.hasPrefix(".") {
                let meta = "\(room)/\(token)/.metadata"
                guard let e = fm.enumerator(atPath: meta) else { continue }
                for case let rel as String in e where rel.hasSuffix(".rb") || rel.hasSuffix(".json") {
                    if let text = try? String(contentsOfFile: "\(meta)/\(rel)", encoding: .utf8),
                       text.contains("\"\(file)\"") { return token }
                }
            }
        }
        return nil
    }

    // MARK: Finding one app's leftovers

    private final class Collector {
        var items: [FoundItem] = []
        var seen: [String: Int] = [:]   // lowercased path -> index
        func add(_ u: URL, _ kind: ItemKind, _ conf: Confidence) {
            let p = u.standardizedFileURL.path
            guard (try? FileManager.default.attributesOfItem(atPath: p)) != nil,   // exists (even broken links)
                  !Scanner.isSIPLocked(u) else { return }                          // macOS-locked: leave alone
            if let i = seen[p.lowercased()] {            // found twice: keep the higher confidence
                if conf > items[i].confidence { items[i].confidence = conf }
                return
            }
            seen[p.lowercased()] = items.count
            let url = URL(fileURLWithPath: p)
            var k = kind
            if (k == .file || k == .app), !Scanner.youCanMove(url) { k = .admin }   // e.g. apps installed by a .pkg
            items.append(FoundItem(url: url, kind: k, confidence: conf))
        }
        func list(_ dir: URL, _ match: (String) -> Confidence?) { list(dir, .file, match) }
        func list(_ dir: URL, _ kind: ItemKind, _ match: (String) -> Confidence?) {
            let names = Scanner.listDir(dir.path)
            for n in names.sorted() where !n.hasPrefix(".") { if let c = match(n) { add(dir.appendingPathComponent(n), kind, c) } }
        }
    }

    static func scan(_ app: TargetApp, withSizes: Bool = true) -> [FoundItem] {
        let L = library, S = systemLibrary
        let bid = app.bundleID.lowercased()
        let c = Collector()

        // "com.foo.bar" or "com.foo.bar.anything" - but never "com.foo.barista" (AppCleaner's plain prefix match would)
        func isBid(_ n: String) -> Bool { let l = n.lowercased(); return l == bid || l.hasPrefix(bid + ".") }

        // Helpers inside the app with their own IDs. A helper that another installed app also contains
        // (e.g. a shared updater) is only "possible", so it isn't ticked for you.
        var helperIDs: [String: Confidence] = [:]
        if let u = app.url {
            let mine = nestedIDs(of: u).filter { !($0 == bid || $0.hasPrefix(bid + ".")) }
            if !mine.isEmpty {
                let others = Set(installedAppsRecent().filter { $0.url?.path != u.path }.flatMap { $0.url.map(nestedIDs) ?? [] })
                for id in mine { helperIDs[id] = others.contains(id) ? .possible : .likely }
            }
        }
        func helper(_ n: String) -> Confidence? {
            let l = n.lowercased()
            for (id, conf) in helperIDs where l == id || l.hasPrefix(id + ".") { return conf }
            return nil
        }
        func bidOnly(_ n: String) -> Confidence? { isBid(n) ? .sure : helper(n) }
        func bidPlist(_ n: String) -> Confidence? {
            guard n.lowercased().hasSuffix(".plist") else { return nil }
            return isBid(n) ? .sure : helper(String(n.dropLast(6)))
        }

        // Names to look for: the app's name, display name and file name ("Minecraft" for "Minecraft Launcher").
        func usable(_ n: String) -> Bool { n.count >= 4 && !genericNames.contains(n) }
        var nameList = [app.name] + [app.displayName2].compactMap { $0 }
        if let f = app.url?.deletingPathExtension().lastPathComponent { nameList.append(f) }
        let lnames = Array(Set(nameList.map { $0.lowercased() })).filter(usable)
        // Weaker forms, like AppCleaner's: without trailing numbers ("Bartender 5" -> "Bartender") -> possible
        let weakNames = Set(lnames.map { stripTrailingDigits($0) }).subtracting(lnames).filter(usable)
        let useName = !lnames.isEmpty
        let normNames = Set((lnames + weakNames).map(normalize))
        // Bundle ID -> sure. Exact name (or "Name.something") -> likely. "Name 2", "NameBeta", "Bartender" -> possible.
        func any(_ n: String) -> Confidence? {
            if isBid(n) { return .sure }
            if let h = helper((n as NSString).deletingPathExtension) ?? helper(n) { return h }
            guard useName else { return nil }
            let l = n.lowercased()
            if lnames.contains(where: { l == $0 || l.hasPrefix($0 + ".") }) { return .likely }
            if weakNames.contains(where: { l == $0 || l.hasPrefix($0 + ".") }) { return .possible }
            return normNames.contains(normalize(stripVersion((n as NSString).deletingPathExtension))) ? .possible : nil
        }
        // Crash reports are named after the program inside the app (AppCleaner uses this too).
        let crashNames = Array(Set(lnames + [app.executable?.lowercased()].compactMap { $0 }.filter { $0.count >= 3 }))

        if let u = app.url, !isOnReadOnlyVolume(u) {      // running from a disk image: nothing to move there
            c.add(u, u.path.hasPrefix("/Library/") ? .admin : .app, .sure)
        }

        // 1. Your Library: matched by bundle ID
        for d in ["Containers", "Application Scripts", "HTTPStorages", "WebKit", "Saved Application State", "Cookies"] {
            c.list(L.appendingPathComponent(d), bidOnly)
        }
        for d in ["Preferences", "Preferences/ByHost", "SyncedPreferences", "LaunchAgents"] { c.list(L.appendingPathComponent(d), bidPlist) }
        c.list(L.appendingPathComponent("Caches/com.apple.helpd/Generated"), bidOnly)   // the app's Help book cache
        c.list(L.appendingPathComponent("Group Containers")) {
            let l = $0.lowercased()
            return l.hasSuffix("." + bid) || l.contains("." + bid + ".") ? .sure : nil
        }
        c.list(L.appendingPathComponent("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments")) {
            $0.lowercased().hasPrefix(bid + ".sfl") ? .sure : nil
        }
        // Shared group folders named in the app's own signed entitlements
        if let u = app.url {
            for g in appGroups(u) where !g.contains("/") && !g.isEmpty {
                c.add(L.appendingPathComponent("Group Containers").appendingPathComponent(g), .file, .sure)
            }
        }

        // Newer macOS can name an app's sandbox folder with a random ID; its metadata file says whose it is.
        let cont = L.appendingPathComponent("Containers")
        for n in Scanner.listDir(cont.path) where n.count == 36 && n.contains("-") {
            let meta = cont.appendingPathComponent(n).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let d = NSDictionary(contentsOf: meta), let id = d["MCMMetadataIdentifier"] as? String, isBid(id) {
                c.add(cont.appendingPathComponent(n), .file, .sure)
            }
        }

        // Plug-ins are also matched by their own bundle ID (e.g. a virtual-camera plug-in that ships with the app).
        let parts = bid.split(separator: ".")
        let vendorID = parts.prefix(2).joined(separator: ".")
        func pluginMatch(_ dir: URL) -> (String) -> Confidence? {
            { n in
                if let conf = any(n) { return conf }
                guard let pb = Scanner.bundleID(of: dir.appendingPathComponent(n))?.lowercased() else { return nil }
                if pb == bid || pb.hasPrefix(bid + ".") { return .sure }
                if parts.count >= 3, vendorID != "com.apple", pb.hasPrefix(vendorID + ".") { return .possible }   // same maker
                return nil
            }
        }
        func libraryFolders(_ root: URL, _ kind: ItemKind) {
            for d in ["Application Support", "Caches", "Logs"] + extraFolders {
                let u = root.appendingPathComponent(d)
                c.list(u, kind, pluginFolders.contains(d) ? pluginMatch(u) : any)
            }
        }
        // Maker folders one level down, e.g. Application Support/<Maker>/<App>
        func makerFolders(_ root: URL, _ kind: ItemKind) {
            let tops = ["Application Support", "Caches", "Logs"].map { root.appendingPathComponent($0) }
            // Only maker folders: never Apple's own data folders, never hidden ones, never already-matched ones
            func isMaker(_ v: String) -> Bool { !v.hasPrefix(".") && !Scanner.isAppleData(v) && any(v) == nil }
            Scanner.prefetch(tops.flatMap { t in Scanner.listDir(t.path).filter(isMaker).map { t.appendingPathComponent($0).path } })
            for top in tops {
                for v in Scanner.listDir(top.path) {
                    if !isMaker(v) { continue }
                    let vu = top.appendingPathComponent(v)
                    guard Scanner.isDirectory(vu), !Scanner.isSymlink(vu) else { continue }
                    c.list(vu, kind) { n in
                        if isBid(n) { return .sure }
                        if lnames.contains(n.lowercased()) { return .likely }
                        return useName && normNames.contains(normalize(stripVersion(n))) ? .possible : nil   // "Brave-Browser"
                    }
                }
            }
        }

        // 2. Your Library: matched by bundle ID or name (and maker folders one level down)
        libraryFolders(L, .file)
        makerFolders(L, .file)
        // Shared by all users of this Mac
        let shared = URL(fileURLWithPath: "/Users/Shared/Library")
        c.list(shared.appendingPathComponent("Application Support"), any)
        makerFolders(shared, .file)
        if useName {
            c.list(L.appendingPathComponent("Application Support/CrashReporter")) { n in
                let l = n.lowercased(); return crashNames.contains { l.hasPrefix($0 + "_") } && l.hasSuffix(".plist") ? .likely : nil
            }
            let crashTypes: Set<String> = ["ips", "crash", "spin", "hang", "diag"]
            c.list(L.appendingPathComponent("Logs/DiagnosticReports")) { n in
                let l = n.lowercased()
                return crashNames.contains { l.hasPrefix($0 + "-") || l.hasPrefix($0 + "_") }
                    && crashTypes.contains((l as NSString).pathExtension) ? .likely : nil
            }
        }

        // Folders directly in ~/Library, /Library and /Users/Shared named after the app (not standard folders)
        func topLevel(_ n: String) -> Confidence? {
            let l = n.lowercased()
            if standardLibraryFolders.contains(l) || neverTouch.contains(l) || l.hasPrefix("com.apple") { return nil }
            if isBid(n) { return .sure }
            return useName && lnames.contains(l) ? .likely : nil
        }
        c.list(L, topLevel)
        c.list(URL(fileURLWithPath: "/Users/Shared"), topLevel)

        // The disk image the app is running from (AppCleaner does this), and installers left in Downloads
        // (AppCleaner doesn't). Both only "possible". Downloads is only read with Full Disk Access, so
        // macOS never pops up a permission question just for this.
        if let u = app.url, let dmg = diskImage(containing: u) { c.add(dmg, .file, .possible) }
        if useName, hasFullDiskAccess() { for u in downloadedInstallers(names: lnames) { c.add(u, .file, .possible) } }

        // A folder in Applications wrapping the app, e.g. /Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app
        if let u = app.url, let w = appWrapperFolder(for: u, names: lnames) { c.add(w, .file, .likely) }

        // 3. macOS's hidden per-app cache and temp folders (/var/folders/...). AppCleaner doesn't look here.
        for d in darwinUserDirs() { c.list(d, bidOnly) }

        // Command-line tool links that point into the app (e.g. /usr/local/bin/code -> Visual Studio Code.app)
        if let appPath = app.url?.resolvingSymlinksInPath().path {
            for dir in commandLineFolders {
                for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                    let u = URL(fileURLWithPath: dir).appendingPathComponent(n)
                    if Scanner.isSymlink(u), u.resolvingSymlinksInPath().path.hasPrefix(appPath + "/") { c.add(u, .file, .sure) }
                }
            }
        }

        // 4. System-wide files (/Library): need your password to move
        libraryFolders(S, .admin)
        makerFolders(S, .admin)
        for d in ["Preferences", "LaunchAgents", "LaunchDaemons"] { c.list(S.appendingPathComponent(d), .admin, bidPlist) }
        c.list(S, .admin, topLevel)
        c.list(S.appendingPathComponent("PrivilegedHelperTools"), .admin, bidOnly)
        // Installer receipts (.plist + .bom). Moving them is like "pkgutil --forget", but undoable.
        c.list(URL(fileURLWithPath: "/private/var/db/receipts"), .receipt) {
            let l = $0.lowercased()
            return (l.hasSuffix(".plist") || l.hasSuffix(".bom")) && isBid((l as NSString).deletingPathExtension) ? .sure : nil
        }

        return withSizes ? Scanner.withSizes(c.items) : c.items
    }

    static func isOnReadOnlyVolume(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    /// If the app runs from a mounted disk image, the .dmg file it came from.
    static func diskImage(containing app: URL) -> URL? {
        guard app.path.hasPrefix("/Volumes/") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = ["info", "-plist"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        for img in images {
            guard let path = img["image-path"] as? String else { continue }
            for e in (img["system-entities"] as? [[String: Any]]) ?? [] {
                if let mp = e["mount-point"] as? String, app.path.hasPrefix(mp + "/") { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    static let installerTypes: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip"]

    /// Installers for this app still sitting in Downloads, e.g. "OBS-Studio-31.0-macOS-Apple.dmg".
    static func downloadedInstallers(names: [String]) -> [URL] {
        let dl = home.appendingPathComponent("Downloads")
        let wanted = Set(names.map(normalize).filter { $0.count >= 4 })
        guard !wanted.isEmpty else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dl.path)) ?? []).compactMap { n in
            guard installerTypes.contains((n as NSString).pathExtension.lowercased()) else { return nil }
            let base = normalize((n as NSString).deletingPathExtension)
            return wanted.contains { base.hasPrefix($0) } ? dl.appendingPathComponent(n) : nil
        }
    }

    /// The folder an app sits in, if that folder is just a wrapper named after the app
    /// (directly inside Applications, and the name starts with the app's name).
    static func appWrapperFolder(for app: URL, names: [String]) -> URL? {
        let parent = app.deletingLastPathComponent()
        let roots = ["/Applications", home.appendingPathComponent("Applications").path]
        guard roots.contains(parent.deletingLastPathComponent().path) else { return nil }
        let folder = normalize(parent.lastPathComponent)
        guard !["utilities"].contains(folder), !names.isEmpty,
              names.contains(where: { folder.hasPrefix(normalize($0)) && !normalize($0).isEmpty }) else { return nil }
        return parent
    }

    /// macOS's per-user cache and temp folders, e.g. /var/folders/xx/yyyy/C and .../T
    static func darwinUserDirs() -> [URL] {
        [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { key in
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard confstr(key, &buf, buf.count) > 0 else { return nil }
            return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
        }
    }

    // MARK: Orphan finder - leftovers of apps that are no longer installed

    /// Folders where files are named after a bundle ID, and how to turn a file name into that bundle ID.
    private static let orphanPlaces: [(String, (String) -> String?)] = [
        ("Application Support", { $0 }), ("Caches", { $0 }), ("Containers", { $0 }),
        ("Application Scripts", { $0 }), ("WebKit", { $0 }), ("Logs", { $0 }),
        ("HTTPStorages", { strip($0, ".binarycookies") }), ("Cookies", { strip($0, ".binarycookies") }),
        ("Saved Application State", { strip($0, ".savedState") }),
        ("Preferences", { $0.hasSuffix(".plist") ? strip($0, ".plist") : nil }),
        ("Preferences/ByHost", { n in
            // com.foo.bar.<hardware-UUID>.plist
            guard n.hasSuffix(".plist") else { return nil }
            var parts = strip(n, ".plist").split(separator: ".").map(String.init)
            if let last = parts.last, last.count >= 12, last.allSatisfy({ $0.isHexDigit || $0 == "-" }) { parts.removeLast() }
            return parts.joined(separator: ".")
        }),
        ("LaunchAgents", { $0.hasSuffix(".plist") ? strip($0, ".plist") : nil }),
    ]

    private static func strip(_ s: String, _ suffix: String) -> String {
        s.lowercased().hasSuffix(suffix.lowercased()) ? String(s.dropLast(suffix.count)) : s
    }

    /// Looks like a reverse-DNS bundle ID, e.g. com.company.app
    static func looksLikeBundleID(_ s: String) -> Bool {
        s.range(of: #"^[a-z]{2,6}\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
    }

    /// Code libraries that many apps build in. Their files usually belong to an app you still have,
    /// so they are never reported as orphans.
    static let sharedLibraryVendors: Set<String> = [
        "com.crashlytics", "com.firebase", "com.google.firebase", "com.hackemist", "com.onevcat",
        "com.segment", "io.sentry", "org.sparkle-project", "com.mixpanel", "com.amplitude", "com.bugsnag",
        "com.microsoft.appcenter", "io.realm", "com.squareup", "net.hockeyapp", "com.plausiblelabs",
        "org.cocoapods", "com.facebook", "com.braze", "io.branch", "com.adjust", "com.appsflyer",
        "com.datadoghq", "com.newrelic", "com.instabug", "org.chromium", "com.github.electron",
    ]

    static func findOrphans(withSizes: Bool = true) -> [FoundItem] {
        let fm = FileManager.default
        let installed = (installedApps() + installedPlugins()).map { $0.bundleID.lowercased() }
        // Vendor = first two parts, e.g. "com.google". Files from a vendor you still have an app from are kept,
        // because vendors often share helpers (updaters, crash reporters) between their apps.
        let installedVendors = Set(installed.map(vendor))
        let me = (Bundle.main.bundleIdentifier ?? "").lowercased()

        var places: [(URL, (String) -> String?)] = orphanPlaces.map { (library.appendingPathComponent($0.0), $0.1) }
        places += darwinUserDirs().map { ($0, { $0 }) }

        var byBid: [String: [URL]] = [:]
        for (d, toBid) in places {
            guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            for n in names where !n.hasPrefix(".") {
                guard var b = toBid(n)?.lowercased() else { continue }
                for g in ["group.", "systemgroup."] where b.hasPrefix(g) { b = String(b.dropFirst(g.count)) }   // group.com.x.y -> com.x.y
                guard looksLikeBundleID(b), !b.contains("com.apple") else { continue }
                byBid[b, default: []].append(d.appendingPathComponent(n))
            }
        }

        var cache: [String: Bool] = [:]
        func stillThere(_ b: String) -> Bool {
            if let v = cache[b] { return v }
            let v = isInstalledAnywhere(b)
            cache[b] = v
            return v
        }

        var out: [FoundItem] = []
        for (b, urls) in byBid {
            if b.hasPrefix("com.apple.") || b == me || b.hasPrefix(me + ".") || ([myBundleID] + oldBundleIDs).contains(b) { continue }
            if sharedLibraryVendors.contains(where: { b == $0 || b.hasPrefix($0 + ".") }) { continue }
            if installedVendors.contains(vendor(b)) { continue }
            if installed.contains(where: { b == $0 || b.hasPrefix($0 + ".") || $0.hasPrefix(b + ".") }) { continue }
            // Also ask macOS: an app with this ID (or its parent ID) may live somewhere else.
            let parts = b.split(separator: ".")
            let candidates = (3...max(3, parts.count)).map { parts.prefix($0).joined(separator: ".") }
            if candidates.contains(where: stillThere) { continue }
            for u in urls where !isSIPLocked(u) {
                out.append(FoundItem(url: u, kind: .file, confidence: .possible, size: -1, group: b))
            }
        }
        out.sort { ($0.group ?? "", $0.url.path) < ($1.group ?? "", $1.url.path) }
        return withSizes ? Scanner.withSizes(out) : out
    }

    private static func vendor(_ b: String) -> String { b.split(separator: ".").prefix(2).joined(separator: ".") }

    // MARK: Safety

    /// Last check right before anything is moved. Each kind may only live in a few known places.
    static func isSafeToTrash(_ item: FoundItem) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: item.url.path)) != nil, !isSIPLocked(item.url) else { return false }
        let last = item.url.lastPathComponent.lowercased()
        if last.hasPrefix("com.apple.") { return false }
        // Apple's own maker folders, e.g. /Library/Application Support/Apple
        let comps = item.url.path.split(separator: "/").map { $0.lowercased() }
        for (i, c) in comps.enumerated() where (c == "application support" || c == "caches") && i + 1 < comps.count {
            if comps[i + 1] == "apple" { return false }
        }
        let link = isSymlink(item.url)
        // Judge a link by where the LINK is (moving a link never touches what it points to).
        let p = link
            ? item.url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(item.url.lastPathComponent).path
            : item.url.standardizedFileURL.resolvingSymlinksInPath().path

        func within(_ roots: [String], maxDepth: Int) -> Bool {
            roots.contains { r in
                let root = r.hasSuffix("/") ? r : r + "/"
                guard p.hasPrefix(root) else { return false }
                let depth = p.dropFirst(root.count).split(separator: "/").count
                return depth >= 1 && depth <= maxDepth
            }
        }
        let cliLink = link && within(commandLineFolders.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, maxDepth: 1)
        if link && !cliLink { return false }       // the only links Crumbs removes are command-line links into an app

        let lib = library.resolvingSymlinksInPath().path + "/"
        let inUserLibrary: Bool = {
            guard p.hasPrefix(lib) else { return false }
            let rest = p.dropFirst(lib.count).split(separator: "/").map { $0.lowercased() }
            guard let first = rest.first, !neverTouch.contains(first) else { return false }
            return rest.count >= 2 || !standardLibraryFolders.contains(first)    // directly in Library: only non-standard folders
        }()
        let topOfSystemLibrary = within(["/Library"], maxDepth: 1) && !standardLibraryFolders.contains(last)
        let inSharedTop = within(["/Users/Shared"], maxDepth: 1) && !["library", "relocated items", ".localized"].contains(last)
        // A wrapper folder in Applications holding app(s), none of them protected
        let isAppWrapper: Bool = {
            guard !link, within(["/Applications", home.resolvingSymlinksInPath().path + "/Applications"], maxDepth: 1),
                  Scanner.isDirectory(item.url), TargetApp.load(item.url) == nil, last != "utilities" else { return false }
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: item.url.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".app") }.compactMap { TargetApp.load(item.url.appendingPathComponent($0)) }
            return !apps.isEmpty && !apps.contains { $0.isProtected }
        }()
        let inDarwinDirs = within(darwinUserDirs().map(\.path), maxDepth: 1)
        let inShared = within(["/Users/Shared/Library/Application Support"], maxDepth: 2)
        let inSystemLibrary = within(["Application Support", "Caches", "Logs"].map { "/Library/" + $0 }, maxDepth: 2)
            || within((["Preferences", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"] + extraFolders).map { "/Library/" + $0 }, maxDepth: 1)
        let isRemovableBundle: Bool = {
            guard !link, let a = TargetApp.load(item.url), !a.isProtected, !p.hasPrefix("/System/"),
                  a.bundleID.lowercased() != myBundleID, !oldBundleIDs.contains(a.bundleID.lowercased()),
                  a.bundleID.lowercased() != (Bundle.main.bundleIdentifier ?? "").lowercased() else { return false }
            let homePath = home.resolvingSymlinksInPath().path + "/"
            return p.hasPrefix("/Applications/") || (p.hasPrefix(homePath) && !p.hasPrefix(lib)) || inUserLibrary || inSystemLibrary
        }()

        // An installer you downloaded (in Downloads), or the disk image an app came from (in your home folder)
        let homePath = home.resolvingSymlinksInPath().path + "/"
        let isInstaller = !link && installerTypes.contains(item.url.pathExtension.lowercased())
            && (within([homePath + "Downloads"], maxDepth: 1) || (last.hasSuffix(".dmg") && p.hasPrefix(homePath) && !p.hasPrefix(lib)))

        switch item.kind {
        case .app:     return isRemovableBundle && !p.hasPrefix("/Library/")
        case .file:    return inUserLibrary || inDarwinDirs || inShared || inSharedTop || cliLink || isAppWrapper || isInstaller
        case .admin:   return isRemovableBundle || inSystemLibrary || topOfSystemLibrary || inUserLibrary || inShared
                           || inSharedTop || cliLink || isAppWrapper
        case .receipt: return within(["/private/var/db/receipts"], maxDepth: 1) && (last.hasSuffix(".plist") || last.hasSuffix(".bom"))
        }
    }

    /// If a folder and something inside it are both chosen, keep only the folder.
    static func withoutNested(_ items: [FoundItem]) -> [FoundItem] {
        let paths = items.map { $0.url.standardizedFileURL.path }
        return items.filter { i in
            let p = i.url.standardizedFileURL.path
            return !paths.contains { $0 != p && p.hasPrefix($0 + "/") }
        }
    }

    // MARK: Helpers

    /// "Sublime Text" -> "sublimetext"
    static func normalize(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// "Name 2" / "Name Beta" / "Name-1.5" -> "Name"
    static func stripVersion(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ ._-]((?i)beta|[0-9][0-9.]*)$"#, with: "", options: .regularExpression)
    }

    private static var groupsCache: [String: (Date, [String])] = [:]

    /// The app's shared group folders, from its signature. Remembered until the app changes.
    static func appGroups(_ url: URL) -> [String] {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("Contents").path))?[.modificationDate] as? Date) ?? .distantPast
        cacheLock.lock()
        if let hit = groupsCache[url.path], hit.0 == mtime { cacheLock.unlock(); return hit.1 }
        cacheLock.unlock()
        let g = readAppGroups(url)
        cacheLock.lock(); groupsCache[url.path] = (mtime, g); cacheLock.unlock()
        return g
    }

    private static func readAppGroups(_ url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return ent["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// Size on disk, measured the same fast way as macOS's `du` (fts, no per-file lookups).
    /// Folders are split by sub-folder across CPU cores (two levels deep), so huge caches go faster than `du`.
    static func size(of url: URL) -> Int64 { sizeSplit(url, depth: 2) }

    private static func sizeSplit(_ url: URL, depth: Int) -> Int64 {
        var st = stat()
        guard depth > 0, lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              let kids = try? FileManager.default.contentsOfDirectory(atPath: url.path), kids.count > 1
        else { return sizeWalk(url) }
        var parts = [Int64](repeating: 0, count: kids.count)
        parts.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: kids.count) { i in
                buf[i] = sizeSplit(url.appendingPathComponent(kids[i]), depth: depth - 1)
            }
        }
        return Int64(st.st_blocks) * 512 + parts.reduce(0, +)
    }

    private static func sizeWalk(_ url: URL) -> Int64 {
        var total: Int64 = 0
        url.path.withCString { cpath in
            let dup = strdup(cpath)
            defer { free(dup) }
            var paths: [UnsafeMutablePointer<CChar>?] = [dup, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let ent = fts_read(fts) {
                switch Int32(ent.pointee.fts_info) {
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_D:     // count every file, link and folder once
                    if let st = ent.pointee.fts_statp { total += Int64(st.pointee.st_blocks) * 512 }
                default: break
                }
            }
        }
        return total
    }

    /// Fills in sizes for many items at once, in parallel.
    static func withSizes(_ items: [FoundItem]) -> [FoundItem] {
        var out = items
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: buf.count) { i in buf[i].size = size(of: buf[i].url) }
        }
        return out
    }

    static func isSymlink(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func prettySize(_ bytes: Int64) -> String {
        bytes < 0 ? "…" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func shortPath(_ url: URL) -> String {
        let p = url.path, h = home.path
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    // MARK: Stopping background services

    /// Unloads a user LaunchAgent before its file is trashed, so it doesn't keep running.
    static func stopLaunchAgentIfNeeded(_ item: FoundItem) {
        let la = library.appendingPathComponent("LaunchAgents").path + "/"
        guard item.url.path.hasPrefix(la), item.url.pathExtension.lowercased() == "plist" else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())", item.url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()   // a non-zero exit just means it wasn't loaded
    }
}
