// System-file mover and tamper-proof Undo, run WITHOUT a password on fake files you own.
import Foundation
let T = URL(fileURLWithPath: CommandLine.arguments[1]); let fm = FileManager.default
func ok(_ c: Bool, _ w: String) { print((c ? "PASS " : "FAIL ") + w) }
func sh(_ s: String) -> [String] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", s]
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); try! p.run(); p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.components(separatedBy: .newlines).filter { !$0.isEmpty }
}
func val(_ out: [String], _ tag: String, _ n: Int) -> String { out.first { $0.hasPrefix("\(tag):\(n):") }.map { String($0.dropFirst("\(tag):\(n):".count)) } ?? "" }
let sys = T.appendingPathComponent("sys")
try! fm.createDirectory(at: sys.appendingPathComponent("Bob's App/sub"), withIntermediateDirectories: true)
try! "hello".write(to: sys.appendingPathComponent("Bob's App/sub/a.txt"), atomically: true, encoding: .utf8)
try! "plist".write(to: sys.appendingPathComponent("com.example.zz.plist"), atomically: true, encoding: .utf8)
for n in ["keep1", "keep2", "keep3"] { try! fm.createDirectory(at: sys.appendingPathComponent(n), withIntermediateDirectories: true)
    try! n.write(to: sys.appendingPathComponent("\(n)/f.txt"), atomically: true, encoding: .utf8) }
let names = ["Bob's App", "com.example.zz.plist", "keep1", "keep2", "keep3"]
let out = sh(Admin.moveScript(for: names.map { FoundItem(url: sys.appendingPathComponent($0), kind: .admin, confidence: .sure) }))
let base = out.first { $0.hasPrefix("BASE:") }.map { String($0.dropFirst(5)) } ?? ""
ok(base.hasPrefix("/private/var/tmp/crumbs."), "holding folder is a fresh system temp folder")
ok((0..<5).allSatisfy { out.contains("OK:\($0)") } && names.allSatisfy { !fm.fileExists(atPath: sys.appendingPathComponent($0).path) }, "all 5 moved out")
ok((0..<5).allSatisfy { val(out, "FP", $0).count == 64 }, "each item has a SHA-256 fingerprint")
let trash = T.appendingPathComponent("trash"); try! fm.createDirectory(at: trash, withIntermediateDirectories: true)
var e: [(trashed: URL, original: URL, owner: String, fingerprint: String, realParent: String)] = []
for (n, name) in names.enumerated() {
    let t = trash.appendingPathComponent(name)
    try! fm.moveItem(at: URL(fileURLWithPath: base).appendingPathComponent("\(n)/\(name)"), to: t)
    e.append((t, sys.appendingPathComponent(name), val(out, "OWN", n), val(out, "FP", n), val(out, "DIR", n)))
}
try! "EVIL".write(to: trash.appendingPathComponent("keep1/f.txt"), atomically: true, encoding: .utf8)          // tamper
try! fm.removeItem(at: trash.appendingPathComponent("keep2")); try! fm.createSymbolicLink(atPath: trash.appendingPathComponent("keep2").path, withDestinationPath: "/etc") // swap
try! fm.createDirectory(at: sys.appendingPathComponent("keep3"), withIntermediateDirectories: true)          // already exists
// parent folder redirected by a link after removal
let par = T.appendingPathComponent("par"); try! fm.createDirectory(at: par, withIntermediateDirectories: true)
try! "x".write(to: par.appendingPathComponent("p.plist"), atomically: true, encoding: .utf8)
let o2 = sh(Admin.moveScript(for: [FoundItem(url: par.appendingPathComponent("p.plist"), kind: .admin, confidence: .sure)]))
let b2 = o2.first { $0.hasPrefix("BASE:") }.map { String($0.dropFirst(5)) } ?? ""
try! fm.moveItem(at: URL(fileURLWithPath: b2 + "/0/p.plist"), to: trash.appendingPathComponent("p.plist"))
try! fm.removeItem(at: par); let elsewhere = T.appendingPathComponent("elsewhere"); try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
try! fm.createSymbolicLink(atPath: par.path, withDestinationPath: elsewhere.path)
e.append((trash.appendingPathComponent("p.plist"), par.appendingPathComponent("p.plist"), "501:20", val(o2, "FP", 0), val(o2, "DIR", 0)))
for b in [base, b2] { for i in 0..<6 { try? fm.removeItem(atPath: b + "/\(i)") }; try? fm.removeItem(atPath: b) }
let r = sh(Admin.restoreScript(e))
ok(r.contains("OK:0") && fm.fileExists(atPath: sys.appendingPathComponent("Bob's App/sub/a.txt").path), "unchanged folder (with apostrophe) put back")
ok(r.contains("OK:1"), "unchanged file put back")
ok(r.contains("CHANGED:2") && fm.fileExists(atPath: trash.appendingPathComponent("keep1/f.txt").path), "TAMPERED folder refused, left in Trash")
ok(r.contains("CHANGED:3"), "item SWAPPED for a link refused")
ok(r.contains("EXISTS:4"), "never overwrites something already there")
ok(r.contains("FAIL:5") && !fm.fileExists(atPath: elsewhere.appendingPathComponent("p.plist").path), "REDIRECTED parent folder refused")
