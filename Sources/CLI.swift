// CLI.swift - the same scanner, from Terminal.
// Part of Crumbs. MIT License.

import Foundation
import AppKit

enum CLI {
    static let usage = """
    Usage:
      Crumbs --scan    <App name | /path/App.app | bundle.id>   list leftovers (changes nothing)
      Crumbs --trash   <App name | /path/App.app | bundle.id>   move app + leftovers to the Trash
      Crumbs --orphans                                          list leftovers of apps no longer installed

    Options:
      --include-possible   with --trash, also trash "possible" matches (normally skipped)
    """

    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static func line(_ i: FoundItem, badge: Bool = true) -> String {
        let size = Scanner.prettySize(i.size)
        let pad = String(repeating: " ", count: max(0, 11 - size.count))
        return pad + size + (badge ? "  [\(i.confidence.label.lowercased())]".padding(toLength: 13, withPad: " ", startingAt: 0) : "  ")
            + Scanner.shortPath(i.url)
    }

    static func run(_ argv: [String]) -> Int32 {
        var args = argv
        let includePossible = args.contains("--include-possible")
        args.removeAll { $0 == "--include-possible" }
        guard let cmd = args.first, ["--scan", "--trash", "--orphans"].contains(cmd) else { print(usage); return 0 }

        if cmd == "--orphans" {
            let items = Scanner.findOrphans()
            if items.isEmpty { print("No orphaned files found."); return 0 }
            var last = ""
            for i in items {
                if i.group != last { last = i.group ?? ""; print("\n" + last) }
                print(line(i, badge: false))
            }
            print("\nTotal: \(Scanner.prettySize(items.reduce(0) { $0 + $1.size })) in \(items.count) item(s)")
            print("Nothing changed. Check each one, then remove it with --trash <bundle.id>.")
            return 0
        }

        guard args.count >= 2 else { print(usage); return 0 }
        let target = args[1]
        guard let app = resolve(target) else { err("Can't find an app called \"\(target)\"."); return 1 }
        if let why = app.protectionReason { err(why + " Not touching it."); return 1 }

        let items = Scanner.scan(app)
        print("\(app.typeLabel): " + (app.url?.path ?? "(already deleted)"))
        print("Bundle ID: \(app.bundleID)\n")
        let user = items.filter { !$0.kind.needsAdmin }, admin = items.filter { $0.kind.needsAdmin }
        for i in user { print(line(i)) }
        if !admin.isEmpty {
            print("\nSystem files (asks for your password):")
            for i in admin { print(line(i)) }
        }
        if items.isEmpty { print("Nothing found. It's already clean.") }
        else { print("\nTotal: \(Scanner.prettySize(items.reduce(0) { $0 + $1.size })) in \(items.count) item(s)") }
        if let cask = Scanner.homebrewCask(for: app) { print("Homebrew installed this app. Also run: brew uninstall --cask \(cask)") }
        guard cmd == "--trash" else { return 0 }

        let chosen = Scanner.withoutNested(items.filter { includePossible || $0.confidence >= .likely })
        let skippedPossible = items.count - chosen.count
        guard !chosen.isEmpty else { print("\nNothing to trash."); return 0 }
        if app.isApp, !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            err("\nThe app is still running. Quit it first."); return 1
        }
        if skippedPossible > 0 { print("\nSkipping \(skippedPossible) \"possible\" item(s). Add --include-possible to include them.") }
        Swift.print("\nMove \(chosen.count) item(s) to the Trash? [y/N] ", terminator: "")
        guard let ans = readLine(), ans.lowercased().hasPrefix("y") else { print("Cancelled. Nothing changed."); return 0 }

        var failed = false
        var toTrash: [(URL, String)] = []      // (file to trash, how to show it)
        var heldForCleanup: [Admin.Held] = []
        for i in chosen where !i.kind.needsAdmin {
            guard Scanner.isSafeToTrash(i) else { print("  SKIPPED  \(Scanner.shortPath(i.url))  (failed safety check)"); failed = true; continue }
            Scanner.stopLaunchAgentIfNeeded(i)
            toTrash.append((i.url, Scanner.shortPath(i.url)))
        }
        let sys = chosen.filter { $0.kind.needsAdmin }
        let safeSys = sys.filter(Scanner.isSafeToTrash)
        for i in sys where !safeSys.contains(i) { print("  SKIPPED  \(i.url.path)  (failed safety check)"); failed = true }
        if !safeSys.isEmpty {
            print("macOS will ask for your password to move \(safeSys.count) system file(s)...")
            let r = Admin.moveToHolding(safeSys)
            if r.cancelled { print("  Password cancelled: system files were not moved."); failed = true }
            else if r.failed > 0 { print("  \(r.failed) system file(s) could not be moved."); failed = true }
            toTrash += r.held.map { ($0.now, $0.original.path) }
            heldForCleanup = r.held
        }
        for (u, shown) in toTrash {
            var out: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                print("  trashed  \(shown)  ->  \(out?.path ?? "?")")
            } catch {
                print("  FAILED   \(shown)  (\(error.localizedDescription))")
                failed = true
            }
        }
        Admin.cleanHolding(heldForCleanup)
        return failed ? 1 : 0
    }

    static func resolve(_ t: String) -> TargetApp? {
        if t.contains("/"), let a = TargetApp.load(URL(fileURLWithPath: t)) { return a }
        let want = (t as NSString).deletingPathExtension.lowercased()
        if let a = (Scanner.installedApps() + Scanner.installedPlugins()).first(where: {
            $0.url?.deletingPathExtension().lastPathComponent.lowercased() == want || $0.name.lowercased() == want
        }) { return a }
        if t.split(separator: ".").count >= 3, !t.contains("/"), !t.contains(" ") { return .byBundleID(t) }
        return nil
    }
}
