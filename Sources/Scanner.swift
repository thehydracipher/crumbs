// Scanner.swift - finds the files an app leaves behind.
// It only looks in known places (no full-disk walk), so it is fast.
// Part of Crumbs. MIT License.

import Foundation
import AppKit
import Security

struct TargetApp: Identifiable, Hashable, Sendable {
    var url: URL?          // nil when the app is already deleted
    var bundleID: String
    var name: String
    var version: String?

    var id: String { url?.path ?? "bundle:" + bundleID }
    var displayName: String { name.isEmpty ? bundleID : name }

    /// Built-in Apple apps are never touched.
    var isProtected: Bool {
        bundleID.lowercased().hasPrefix("com.apple.") || (url?.path.hasPrefix("/System/") ?? false)
    }

    static func load(_ url: URL) -> TargetApp? {
        guard url.pathExtension.lowercased() == "app",
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
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
    case app       // the app itself
    case file      // a leftover in your home folder
    case admin     // a system file, needs an admin password
    case receipt   // an installer receipt (info only)

    var trashable: Bool { self == .app || self == .file }
}

/// How sure we are that a file belongs to the app.
enum Confidence: Int, Comparable, Sendable {
    case possible = 0   // looks similar (e.g. "Name 2", "NameBeta"). Never ticked by default.
    case likely = 1     // folder has exactly the app's name
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
}

enum Scanner {
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var library: URL { home.appendingPathComponent("Library") }

    /// Names too vague to match safely. For these we only match by bundle ID.
    static let genericNames: Set<String> = [
        "app", "apps", "helper", "update", "updater", "data", "cache", "caches", "logs",
        "tmp", "temp", "google", "microsoft", "adobe", "apple", "mozilla", "default",
        "mail", "notes", "code", "sync", "music", "photos", "preview", "settings",
    ]

    // MARK: Finding installed apps

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
        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Is an app with this bundle ID installed anywhere (not counting the Trash)?
    static func isInstalledAnywhere(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { u in
            !u.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: u.path)
        }
    }

    // MARK: Finding one app's leftovers

    private final class Collector {
        var items: [FoundItem] = []
        var seen: [String: Int] = [:]   // lowercased path -> index
        func add(_ u: URL, _ kind: ItemKind, _ conf: Confidence) {
            let p = u.standardizedFileURL.path
            guard (try? FileManager.default.attributesOfItem(atPath: p)) != nil else { return } // exists (even broken links)
            if let i = seen[p.lowercased()] {            // found twice: keep the higher confidence
                if conf > items[i].confidence { items[i].confidence = conf }
                return
            }
            seen[p.lowercased()] = items.count
            items.append(FoundItem(url: URL(fileURLWithPath: p), kind: kind, confidence: conf))
        }
        func list(_ dir: URL, _ match: (String) -> Confidence?) { list(dir, .file, match) }
        func list(_ dir: URL, _ kind: ItemKind, _ match: (String) -> Confidence?) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names.sorted() { if let c = match(n) { add(dir.appendingPathComponent(n), kind, c) } }
        }
    }

    static func scan(_ app: TargetApp, withSizes: Bool = true) -> [FoundItem] {
        let L = library
        let bid = app.bundleID.lowercased()
        let c = Collector()

        // "com.foo.bar" or "com.foo.bar.anything" - but never "com.foo.barista"
        func isBid(_ n: String) -> Bool { let l = n.lowercased(); return l == bid || l.hasPrefix(bid + ".") }
        func bidOnly(_ n: String) -> Confidence? { isBid(n) ? .sure : nil }
        func bidPlist(_ n: String) -> Confidence? { isBid(n) && n.lowercased().hasSuffix(".plist") ? .sure : nil }

        if let u = app.url { c.add(u, .app, .sure) }

        // 1. Matches by bundle ID (exact, safe)
        for d in ["Application Support", "Caches", "Containers", "Application Scripts",
                  "HTTPStorages", "WebKit", "Logs", "Saved Application State", "Cookies"] {
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

        // 2. Shared group folders named in the app's own signed entitlements
        if let u = app.url {
            for g in appGroups(u) where !g.contains("/") && !g.isEmpty {
                c.add(L.appendingPathComponent("Group Containers").appendingPathComponent(g), .file, .sure)
            }
        }

        // 3. Matches by app name
        let name = app.name, lname = name.lowercased()
        let useName = name.count >= 4 && !genericNames.contains(lname)
        if useName {
            let normName = normalize(name)
            // Exact name -> likely. "Name 2", "Name Beta", "NameApp-1.5", "name_app" -> possible.
            func nameMatch(_ n: String) -> Confidence? {
                if n.lowercased() == lname { return .likely }
                let base = stripVersion(n)
                return normalize(base) == normName ? .possible : nil
            }
            for d in ["Application Support", "Caches", "Logs"] { c.list(L.appendingPathComponent(d), nameMatch) }
            c.list(L.appendingPathComponent("Application Support/CrashReporter")) {
                let l = $0.lowercased(); return l.hasPrefix(lname + "_") && l.hasSuffix(".plist") ? .likely : nil
            }
            let crashTypes: Set<String> = ["ips", "crash", "spin", "hang", "diag"]
            c.list(L.appendingPathComponent("Logs/DiagnosticReports")) {
                let l = $0.lowercased()
                return (l.hasPrefix(lname + "-") || l.hasPrefix(lname + "_"))
                    && crashTypes.contains((l as NSString).pathExtension) ? .likely : nil
            }
            for d in ["Internet Plug-Ins", "PreferencePanes", "QuickLook", "Spotlight", "Services", "Screen Savers"] {
                c.list(L.appendingPathComponent(d)) { $0.lowercased().hasPrefix(lname + ".") ? .likely : nil }
            }
        }

        // 4. System-wide files: shown, but need an admin password to remove
        let sys = URL(fileURLWithPath: "/Library")
        for d in ["LaunchAgents", "LaunchDaemons"] { c.list(sys.appendingPathComponent(d), .admin, bidPlist) }
        c.list(sys.appendingPathComponent("PrivilegedHelperTools"), .admin, bidOnly)
        c.list(sys.appendingPathComponent("Application Support"), .admin) {
            isBid($0) ? .sure : (useName && $0.lowercased() == lname ? .likely : nil)
        }
        c.list(URL(fileURLWithPath: "/private/var/db/receipts"), .receipt) {
            let l = $0.lowercased(); return l.hasSuffix(".plist") && l.contains(bid) ? .sure : nil
        }

        var items = c.items
        if withSizes {
            for i in items.indices where items[i].kind != .receipt { items[i].size = size(of: items[i].url) }
        }
        return items
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

    static func findOrphans() -> [FoundItem] {
        let L = library
        let fm = FileManager.default
        let installed = installedApps().map { $0.bundleID.lowercased() }
        // Vendor = first two parts, e.g. "com.google". Files from a vendor you still have an app from are kept,
        // because vendors often share helpers (updaters, crash reporters) between their apps.
        let installedVendors = Set(installed.map(vendor))
        let me = (Bundle.main.bundleIdentifier ?? "").lowercased()

        var byBid: [String: [URL]] = [:]
        for (dir, toBid) in orphanPlaces {
            let d = L.appendingPathComponent(dir)
            guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            for n in names where !n.hasPrefix(".") {
                guard let b = toBid(n), looksLikeBundleID(b) else { continue }
                byBid[b.lowercased(), default: []].append(d.appendingPathComponent(n))
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
            if sharedLibraryVendors.contains(vendor(b)) { continue }
            if installedVendors.contains(vendor(b)) { continue }
            if installed.contains(where: { b == $0 || b.hasPrefix($0 + ".") || $0.hasPrefix(b + ".") }) { continue }
            // Also ask macOS: an app with this ID (or its parent ID) may live somewhere else.
            let parts = b.split(separator: ".")
            let candidates = (3...max(3, parts.count)).map { parts.prefix($0).joined(separator: ".") }
            if candidates.contains(where: stillThere) { continue }
            for u in urls {
                out.append(FoundItem(url: u, kind: .file, confidence: .possible, size: size(of: u), group: b))
            }
        }
        return out.sorted { ($0.group ?? "", $0.url.path) < ($1.group ?? "", $1.url.path) }
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

    private static func vendor(_ b: String) -> String { b.split(separator: ".").prefix(2).joined(separator: ".") }

    // MARK: Safety

    /// Last check right before anything is moved. Only an app bundle, or something inside a
    /// sub-folder of ~/Library, may ever be trashed. Never Library itself or its main folders.
    static func isSafeToTrash(_ item: FoundItem) -> Bool {
        let p = item.url.standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: item.url.path) || (try? FileManager.default.attributesOfItem(atPath: item.url.path)) != nil
        else { return false }
        switch item.kind {
        case .app:
            guard item.url.pathExtension.lowercased() == "app", !p.hasPrefix("/System/"),
                  let a = TargetApp.load(item.url), !a.isProtected,
                  a.bundleID.lowercased() != (Bundle.main.bundleIdentifier ?? "").lowercased()
            else { return false }
            return true
        case .file:
            let lib = library.resolvingSymlinksInPath().path + "/"
            guard p.hasPrefix(lib) else { return false }
            let rest = p.dropFirst(lib.count).split(separator: "/")
            return rest.count >= 2 && !(rest.last ?? "").lowercased().hasPrefix("com.apple.")
        case .admin, .receipt:
            return false
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
