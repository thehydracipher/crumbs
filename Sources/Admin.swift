// Admin.swift - moves system files (in /Library) to the Trash, using ONE macOS password prompt.
// Crumbs never sees your password: macOS asks for it in its own window.
// Part of Crumbs. MIT License.

import Foundation

enum Admin {
    struct Result {
        var held: [(now: URL, original: URL)] = []   // files now in a folder you own, ready for the Trash
        var failed = 0
        var cancelled = false       // you clicked Cancel on the password prompt
    }

    /// Where system files wait (owned by you) before they go to the Trash.
    static var holdingRoot: URL {
        Scanner.library.appendingPathComponent("Application Support/io.github.rus024.crumbs/Holding")
    }

    /// Quote a path for the shell: 'it'\''s' style.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The shell commands, run once as administrator:
    /// stop launchd jobs, move each item into a holding folder, then hand the folder to you.
    static func script(for items: [FoundItem], holding base: URL) -> String {
        let uid = getuid()
        var cmds = ["/bin/mkdir -p \(q(base.path))"]
        for (n, item) in items.enumerated() {
            let p = item.url.path
            if p.hasPrefix("/Library/LaunchDaemons/") {
                cmds.append("/bin/launchctl bootout system \(q(p)) >/dev/null 2>&1 || true")
            } else if p.hasPrefix("/Library/LaunchAgents/") {
                cmds.append("/bin/launchctl bootout gui/\(uid) \(q(p)) >/dev/null 2>&1 || true")
            }
            let dir = base.appendingPathComponent(String(n))
            let dest = dir.appendingPathComponent(item.url.lastPathComponent)
            cmds.append("/bin/mkdir -p \(q(dir.path)) && /bin/mv \(q(p)) \(q(dest.path)) && echo OK:\(n) || echo FAIL:\(n)")
        }
        cmds.append("/usr/sbin/chown -R \(uid) \(q(base.path))")
        return cmds.joined(separator: "; ")
    }

    /// Runs the script with administrator rights. macOS shows its own password prompt.
    static func moveToHolding(_ items: [FoundItem]) -> Result {
        guard !items.isEmpty else { return Result() }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let base = holdingRoot.appendingPathComponent(stamp)
        try? FileManager.default.createDirectory(at: holdingRoot, withIntermediateDirectories: true)

        let shell = script(for: items, holding: base)
        let appleScriptText = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(appleScriptText)\" with prompt \"Crumbs wants to move system files to the Trash.\" with administrator privileges"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return Result(failed: items.count) }
        p.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var r = Result()
        if p.terminationStatus != 0 && stderr.contains("-128") { r.cancelled = true; return r }
        let lines = stdout.components(separatedBy: CharacterSet.newlines)
        for (n, item) in items.enumerated() {
            if lines.contains("OK:\(n)") {
                r.held.append((base.appendingPathComponent(String(n)).appendingPathComponent(item.url.lastPathComponent), item.url))
            } else {
                r.failed += 1
            }
        }
        return r
    }

    /// Puts system files back from the Trash (one password prompt) and gives them back to the system owner.
    /// Returns how many were put back.
    static func restore(_ pairs: [(from: URL, to: URL)]) -> Int {
        let cmds = pairs.map { f, t in
            "/bin/mv -n \(q(f.path)) \(q(t.path)) && /usr/sbin/chown -R root:wheel \(q(t.path)) && echo OK || echo FAIL"
        }.joined(separator: "; ")
        let text = cmds.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(text)\" with prompt \"Crumbs wants to put system files back.\" with administrator privileges"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.components(separatedBy: .newlines).filter { $0 == "OK" }.count
    }

    /// Removes empty holding folders after their contents went to the Trash.
    static func cleanHolding() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: holdingRoot, includingPropertiesForKeys: nil) else { return }
        let dirs = e.compactMap { $0 as? URL }.sorted { $0.path.count > $1.path.count }   // deepest first
        for d in dirs where (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true { try? fm.removeItem(at: d) }
    }
}
