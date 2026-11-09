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
        if app.isProtected { err("That is a built-in Apple app. Not touching it."); return 1 }

        let items = Scanner.scan(app)
        print("App:       \(app.url?.path ?? "(already deleted)")")
        print("Bundle ID: \(app.bundleID)\n")
        let trashable = items.filter { $0.kind.trashable }
        for i in trashable { print(line(i)) }
        if trashable.isEmpty { print("Nothing found. It's already clean.") }
        else { print("\nTotal: \(Scanner.prettySize(trashable.reduce(0) { $0 + $1.size })) in \(trashable.count) item(s)") }
        let other = items.filter { !$0.kind.trashable }
        if !other.isEmpty {
            print("\nSystem files (need admin, not touched):")
            for i in other { print("  " + i.url.path) }
        }
        guard cmd == "--trash" else { return 0 }

        let chosen = trashable.filter { includePossible || $0.confidence >= .likely }
        let skippedPossible = trashable.count - chosen.count
        guard !chosen.isEmpty else { print("\nNothing to trash."); return 0 }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            err("\nThe app is still running. Quit it first."); return 1
        }
        if skippedPossible > 0 { print("\nSkipping \(skippedPossible) \"possible\" item(s). Add --include-possible to include them.") }
        Swift.print("\nMove \(chosen.count) item(s) to the Trash? [y/N] ", terminator: "")
        guard let ans = readLine(), ans.lowercased().hasPrefix("y") else { print("Cancelled. Nothing changed."); return 0 }

        var failed = false
        for i in chosen {
            guard Scanner.isSafeToTrash(i) else { print("  SKIPPED  \(Scanner.shortPath(i.url))  (failed safety check)"); failed = true; continue }
            Scanner.stopLaunchAgentIfNeeded(i)
            var out: NSURL?
            do {
                try FileManager.default.trashItem(at: i.url, resultingItemURL: &out)
                print("  trashed  \(Scanner.shortPath(i.url))  ->  \(out?.path ?? "?")")
            } catch {
                print("  FAILED   \(Scanner.shortPath(i.url))  (\(error.localizedDescription))")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    static func resolve(_ t: String) -> TargetApp? {
        if t.hasSuffix(".app"), let a = TargetApp.load(URL(fileURLWithPath: t)) { return a }
        let want = (t as NSString).deletingPathExtension.lowercased()
        if let a = Scanner.installedApps().first(where: {
            $0.url?.deletingPathExtension().lastPathComponent.lowercased() == want || $0.name.lowercased() == want
        }) { return a }
        if t.split(separator: ".").count >= 3, !t.contains("/"), !t.contains(" ") { return .byBundleID(t) }
        return nil
    }
}
