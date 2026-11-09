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
        if let u = url, Scanner.isSIPLocked(u) { return "macOS protects this app (System Integrity Protection)." }
        if Scanner.userProtectedIDs().contains(bundleID.lowercased()) { return "You protected this app." }
        return nil
    }
    var isUserProtected: Bool { Scanner.userProtectedIDs().contains(bundleID.lowercased()) }

    static func load(_ url: URL) -> TargetApp? {
        guard Scanner.bundleTypes[url.pathExtension.lowercased()] != nil,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                ?? NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
                ?? NSDictionary(contentsOf: url.appendingPathComponent("WrappedBundle/Info.plist")),   // iPhone/iPad apps
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        let name = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        return TargetApp(url: url, bundleID: id, name: name,
                         version: info["CFBundleShortVersionString"] as? String)
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
    var size: Int64 = 0
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
        "action": "Automator Action",
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

    static let myBundleID = "io.github.rus024.crumbs"

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
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names.sorted() where !n.hasPrefix(".") { if let c = match(n) { add(dir.appendingPathComponent(n), kind, c) } }
        }
    }

    static func scan(_ app: TargetApp, withSizes: Bool = true) -> [FoundItem] {
        let L = library, S = systemLibrary
        let bid = app.bundleID.lowercased()
        let c = Collector()

        // "com.foo.bar" or "com.foo.bar.anything" - but never "com.foo.barista"
        func isBid(_ n: String) -> Bool { let l = n.lowercased(); return l == bid || l.hasPrefix(bid + ".") }
        func bidOnly(_ n: String) -> Confidence? { isBid(n) ? .sure : nil }
        func bidPlist(_ n: String) -> Confidence? { isBid(n) && n.lowercased().hasSuffix(".plist") ? .sure : nil }

        // Names to look for: the app's own name, plus its file name if different ("Minecraft" for "Minecraft Launcher").
        var nameList = [app.name]
        if let f = app.url?.deletingPathExtension().lastPathComponent, f.lowercased() != app.name.lowercased() { nameList.append(f) }
        let lnames = nameList.map { $0.lowercased() }.filter { $0.count >= 4 && !genericNames.contains($0) }
        let useName = !lnames.isEmpty
        let normNames = Set(lnames.map(normalize))
        // Bundle ID -> sure. Exact name (or "Name.something") -> likely. "Name 2", "NameBeta" -> possible.
        func any(_ n: String) -> Confidence? {
            if isBid(n) { return .sure }
            guard useName else { return nil }
            let l = n.lowercased()
            if lnames.contains(where: { l == $0 || l.hasPrefix($0 + ".") }) { return .likely }
            return normNames.contains(normalize(stripVersion((n as NSString).deletingPathExtension))) ? .possible : nil
        }

        if let u = app.url { c.add(u, u.path.hasPrefix("/Library/") ? .admin : .app, .sure) }

        // 1. Your Library: matched by bundle ID
        for d in ["Containers", "Application Scripts", "HTTPStorages", "WebKit", "Saved Application State", "Cookies"] {
            c.list(L.appendingPathComponent(d), bidOnly)
        }
        for d in ["Preferences", "Preferences/ByHost", "LaunchAgents"] { c.list(L.appendingPathComponent(d), bidPlist) }
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
        for n in (try? FileManager.default.contentsOfDirectory(atPath: cont.path)) ?? [] where n.count == 36 && n.contains("-") {
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
            for d in ["Application Support", "Caches", "Logs"] {
                let top = root.appendingPathComponent(d)
                for v in (try? FileManager.default.contentsOfDirectory(atPath: top.path)) ?? [] {
                    let lv = v.lowercased()
                    if v.hasPrefix(".") || lv.hasPrefix("com.apple") || lv == "apple" || lv == "crashreporter" || any(v) != nil { continue }
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
                let l = n.lowercased(); return lnames.contains { l.hasPrefix($0 + "_") } && l.hasSuffix(".plist") ? .likely : nil
            }
            let crashTypes: Set<String> = ["ips", "crash", "spin", "hang", "diag"]
            c.list(L.appendingPathComponent("Logs/DiagnosticReports")) { n in
                let l = n.lowercased()
                return lnames.contains { l.hasPrefix($0 + "-") || l.hasPrefix($0 + "_") }
                    && crashTypes.contains((l as NSString).pathExtension) ? .likely : nil
            }
        }

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
        c.list(S.appendingPathComponent("PrivilegedHelperTools"), .admin, bidOnly)
        // Installer receipts (.plist + .bom). Moving them is like "pkgutil --forget", but undoable.
        c.list(URL(fileURLWithPath: "/private/var/db/receipts"), .receipt) {
            let l = $0.lowercased()
            return (l.hasSuffix(".plist") || l.hasSuffix(".bom")) && isBid((l as NSString).deletingPathExtension) ? .sure : nil
        }

        var items = c.items
        if withSizes {
            for i in items.indices { items[i].size = size(of: items[i].url) }
        }
        return items
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

    static func findOrphans() -> [FoundItem] {
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
            if b.hasPrefix("com.apple.") || b == me || b.hasPrefix(me + ".") { continue }
            if sharedLibraryVendors.contains(where: { b == $0 || b.hasPrefix($0 + ".") }) { continue }
            if installedVendors.contains(vendor(b)) { continue }
            if installed.contains(where: { b == $0 || b.hasPrefix($0 + ".") || $0.hasPrefix(b + ".") }) { continue }
            // Also ask macOS: an app with this ID (or its parent ID) may live somewhere else.
            let parts = b.split(separator: ".")
            let candidates = (3...max(3, parts.count)).map { parts.prefix($0).joined(separator: ".") }
            if candidates.contains(where: stillThere) { continue }
            for u in urls where !isSIPLocked(u) {
                out.append(FoundItem(url: u, kind: .file, confidence: .possible, size: size(of: u), group: b))
            }
        }
        return out.sorted { ($0.group ?? "", $0.url.path) < ($1.group ?? "", $1.url.path) }
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
            return rest.count >= 2 && !neverTouch.contains(rest[0])
        }()
        let inDarwinDirs = within(darwinUserDirs().map(\.path), maxDepth: 1)
        let inShared = within(["/Users/Shared/Library/Application Support"], maxDepth: 2)
        let inSystemLibrary = within(["Application Support", "Caches", "Logs"].map { "/Library/" + $0 }, maxDepth: 2)
            || within((["Preferences", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"] + extraFolders).map { "/Library/" + $0 }, maxDepth: 1)
        let isRemovableBundle: Bool = {
            guard !link, let a = TargetApp.load(item.url), !a.isProtected, !p.hasPrefix("/System/"),
                  a.bundleID.lowercased() != myBundleID,
                  a.bundleID.lowercased() != (Bundle.main.bundleIdentifier ?? "").lowercased() else { return false }
            let homePath = home.resolvingSymlinksInPath().path + "/"
            return p.hasPrefix("/Applications/") || (p.hasPrefix(homePath) && !p.hasPrefix(lib)) || inUserLibrary || inSystemLibrary
        }()

        switch item.kind {
        case .app:     return isRemovableBundle && !p.hasPrefix("/Library/")
        case .file:    return inUserLibrary || inDarwinDirs || inShared || cliLink
        case .admin:   return isRemovableBundle || inSystemLibrary || inUserLibrary || inShared || cliLink
        case .receipt: return within(["/private/var/db/receipts"], maxDepth: 1) && (last.hasSuffix(".plist") || last.hasSuffix(".bom"))
        }
    }

    // MARK: Helpers

    /// "Sublime Text" -> "sublimetext"
    static func normalize(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// "Name 2" / "Name Beta" / "Name-1.5" -> "Name"
    static func stripVersion(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ ._-]((?i)beta|[0-9][0-9.]*)$"#, with: "", options: .regularExpression)
    }

    /// Reads com.apple.security.application-groups from the app's code signature.
    static func appGroups(_ url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return ent["com.apple.security.application-groups"] as? [String] ?? []
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func one(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys) else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        var total = one(url)
        if isDirectory(url),
           let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                  options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e { total += one(u) }
        }
        return total
    }

    static func isSymlink(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func prettySize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
