// Admin.swift - moves system files to the Trash (and back), using ONE macOS password prompt each time.
// Crumbs never sees your password: macOS asks for it in its own window.
//
// Safety:
// - Files are first moved into a fresh folder that only the system (root) can touch, so no other
//   program can interfere halfway. Only then is the folder handed to you and sent to the Trash.
// - Each item gets a fingerprint (SHA-256 of its contents). Undo moves the item out of the Trash into
//   a root-only folder FIRST, checks the fingerprint, and only puts it back if nothing changed.
//   So nothing can swap a file in your Trash and get it installed as a system file.
//
// Part of Crumbs. MIT License.

import Foundation

enum Admin {
    struct Held: Sendable {
        let now: URL           // where it is now (a folder you own, ready for the Trash)
        let original: URL      // where it came from
        let owner: String      // original "uid:gid", restored on Undo
        let fingerprint: String
        let realParent: String // the parent folder's true path at removal time (Undo checks it's unchanged)
    }
    struct Result {
        var held: [Held] = []
        var failed = 0
        var cancelled = false  // you clicked Cancel on the password prompt
    }

    /// Quote a path for the shell: 'it'\''s' style.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Shell function: fingerprint of a file, link or folder (contents and link targets, not dates).
    static let fingerprintFunction = """
    fp() { if [ -L "$1" ]; then /usr/bin/readlink "$1" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64; \
    elif [ -d "$1" ]; then ( cd "$1" && { /usr/bin/find . -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256; \
    /usr/bin/find . -type l -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 -n1 /usr/bin/readlink; /usr/bin/find . | /usr/bin/sort; } 2>/dev/null ) \
    | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64; else /usr/bin/shasum -a 256 < "$1" | /usr/bin/cut -c1-64; fi; }
    """

    /// The shell commands for moving items out, run once as administrator.
    static func moveScript(for items: [FoundItem]) -> String {
        let uid = getuid()
        var cmds = [fingerprintFunction,
                    "B=$(/usr/bin/mktemp -d /private/var/tmp/crumbs.XXXXXX) || exit 1",   // root-only folder
                    "echo BASE:$B"]
        for (n, item) in items.enumerated() {
            let p = q(item.url.path)
            if item.url.path.hasPrefix("/Library/LaunchDaemons/") {
                cmds.append("/bin/launchctl bootout system \(p) >/dev/null 2>&1 || true")
            } else if item.url.path.hasPrefix("/Library/LaunchAgents/") {
                cmds.append("/bin/launchctl bootout gui/\(uid) \(p) >/dev/null 2>&1 || true")
            }
            cmds.append("echo OWN:\(n):$(/usr/bin/stat -f %u:%g \(p))")
            cmds.append("echo DIR:\(n):$(cd \(q(item.url.deletingLastPathComponent().path)) && /bin/pwd -P)")
            cmds.append("/bin/mkdir \"$B/\(n)\" && /bin/mv \(p) \"$B/\(n)/\" && echo OK:\(n) && echo FP:\(n):$(fp \"$B/\(n)/\"\(q(item.url.lastPathComponent))) || echo FAIL:\(n)")
        }
        cmds.append("/usr/sbin/chown -R \(uid) \"$B\"")      // hand the folder to you only at the very end
        return cmds.joined(separator: "\n")
    }

    /// Runs shell commands as administrator. macOS shows its own password prompt.
    /// Returns (output lines, cancelled).
    static func runAsAdmin(_ shell: String, prompt: String) -> (lines: [String], cancelled: Bool, ran: Bool) {
        // The commands go straight to macOS, never through a file that another program could edit first.
        let text = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(text)\" with prompt \"\(prompt)\" with administrator privileges"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ([], false, false) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let cancelled = p.terminationStatus != 0 && stderr.contains("-128")
        return (stdout.components(separatedBy: CharacterSet.newlines), cancelled, true)
    }

    /// Moves system files into a root-only folder, then hands it to you (so it can go to the Trash).
    static func moveToHolding(_ items: [FoundItem]) -> Result {
        guard !items.isEmpty else { return Result() }
        let (lines, cancelled, ran) = runAsAdmin(moveScript(for: items), prompt: "Crumbs wants to move system files to the Trash.")
        var r = Result()
        if cancelled { r.cancelled = true; return r }
        guard ran, let baseLine = lines.first(where: { $0.hasPrefix("BASE:") }) else { r.failed = items.count; return r }
        let base = URL(fileURLWithPath: String(baseLine.dropFirst(5)))
        func value(_ tag: String, _ n: Int) -> String? {
            lines.first { $0.hasPrefix("\(tag):\(n):") }.map { String($0.dropFirst("\(tag):\(n):".count)) }
        }
        for (n, item) in items.enumerated() {
            guard lines.contains("OK:\(n)"), let fpv = value("FP", n), fpv.count == 64 else { r.failed += 1; continue }
            r.held.append(Held(now: base.appendingPathComponent(String(n)).appendingPathComponent(item.url.lastPathComponent),
                               original: item.url, owner: value("OWN", n) ?? "0:0", fingerprint: fpv,
                               realParent: value("DIR", n) ?? item.url.deletingLastPathComponent().path))
        }
        return r
    }

    /// Puts system files back from the Trash. Each item is first moved into a root-only folder,
    /// its fingerprint is checked, and only an unchanged item is put back (with its original owner).
    /// Returns how many were put back and how many were refused because they had changed.
    static func restore(_ entries: [(trashed: URL, original: URL, owner: String, fingerprint: String, realParent: String)]) -> (ok: Int, changed: Int) {
        let (lines, _, _) = runAsAdmin(restoreScript(entries), prompt: "Crumbs wants to put system files back.")
        return (lines.filter { $0.hasPrefix("OK:") }.count, lines.filter { $0.hasPrefix("CHANGED:") }.count)
    }

    /// The shell commands for putting items back (separate so they can be tested without a password).
    static func restoreScript(_ entries: [(trashed: URL, original: URL, owner: String, fingerprint: String, realParent: String)]) -> String {
        let uid = getuid()
        var cmds = [fingerprintFunction,
                    "R=$(/usr/bin/mktemp -d /private/var/tmp/crumbs-undo.XXXXXX) || exit 1"]
        for (n, e) in entries.enumerated() {
            let t = q(e.trashed.path), o = q(e.original.path)
            let parent = e.original.deletingLastPathComponent().path
            let own = e.owner.allSatisfy { $0.isNumber || $0 == ":" } ? e.owner : "0:0"
            let fpv = e.fingerprint.allSatisfy { $0.isHexDigit } ? e.fingerprint : "invalid"
            // The parent folder must really be where we expect (no link redirecting it elsewhere).
            cmds.append("""
            if [ -e \(o) ]; then echo EXISTS:\(n); \
            elif /bin/mv \(t) "$R/\(n)"; then \
              if [ "$(fp "$R/\(n)")" = '\(fpv)' ]; then \
                /bin/mkdir -p \(q(parent)) && [ "$(cd \(q(parent)) && /bin/pwd -P)" = \(q(e.realParent)) ] \
                && /bin/mv "$R/\(n)" \(o) && /usr/sbin/chown -R \(own) \(o) && echo OK:\(n) \
                || { [ -e "$R/\(n)" ] && /usr/sbin/chown -R \(uid) "$R/\(n)" && /bin/mv "$R/\(n)" \(t); echo FAIL:\(n); }; \
              else /usr/sbin/chown -R \(uid) "$R/\(n)"; /bin/mv "$R/\(n)" \(t); echo CHANGED:\(n); fi; \
            else echo FAIL:\(n); fi
            """)
        }
        cmds.append("/bin/rmdir \"$R\" 2>/dev/null; true")
        return cmds.joined(separator: "\n")
    }

    /// Removes the (now empty) folders that held system files on their way to the Trash.
    static func cleanHolding(_ held: [Held]) {
        let fm = FileManager.default
        let bases = Set(held.map { $0.now.deletingLastPathComponent().deletingLastPathComponent() })
        for base in bases where base.path.hasPrefix("/private/var/tmp/crumbs.") {
            for sub in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                if (try? fm.contentsOfDirectory(atPath: sub.path))?.isEmpty == true { try? fm.removeItem(at: sub) }
            }
            if (try? fm.contentsOfDirectory(atPath: base.path))?.isEmpty == true { try? fm.removeItem(at: base) }
        }
    }
}
