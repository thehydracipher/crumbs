// Safety rules: what Crumbs may and may not move.
import Foundation
import AppKit
let W = CommandLine.arguments[1]; let F = W + "/home"; let fm = FileManager.default
func ok(_ c: Bool, _ w: String) { print((c ? "PASS " : "FAIL ") + w) }
func mk(_ p: String) { try! fm.createDirectory(atPath: F + "/" + p, withIntermediateDirectories: true) }
for d in ["Library/Keychains/k", "Library/Mobile Documents/m", "Library/Caches/com.x.app", "bin", "Applications/Foo.app/Contents/MacOS",
          "target", "Library/Caches", "Library/SomeAppFolder", "Applications/Foo 2024/Foo.app/Contents"] { mk(d) }
try! "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.x.foo</string></dict></plist>"
    .write(toFile: F + "/Applications/Foo.app/Contents/Info.plist", atomically: true, encoding: .utf8)
try! fm.copyItem(atPath: F + "/Applications/Foo.app/Contents/Info.plist", toPath: F + "/Applications/Foo 2024/Foo.app/Contents/Info.plist")
fm.createFile(atPath: F + "/Applications/Foo.app/Contents/MacOS/foo", contents: Data())
try! fm.createSymbolicLink(atPath: F + "/bin/foo", withDestinationPath: F + "/Applications/Foo.app/Contents/MacOS/foo")
try! fm.createSymbolicLink(atPath: F + "/Library/Caches/linkout", withDestinationPath: "/Users")
try! fm.createSymbolicLink(atPath: F + "/Library/Caches/com.zz.link", withDestinationPath: F + "/target")
fm.createFile(atPath: F + "/target/keep.txt", contents: Data("keep".utf8))
func safe(_ p: String, _ k: ItemKind) -> Bool { Scanner.isSafeToTrash(FoundItem(url: URL(fileURLWithPath: p), kind: k, confidence: .sure)) }
ok(!safe(F + "/Library/Keychains/k", .file), "Keychains refused")
ok(!safe(F + "/Library/Mobile Documents/m", .admin), "iCloud Drive refused, even with password")
ok(safe(F + "/Library/Caches/com.x.app", .file), "normal cache folder allowed")
ok(!safe(F + "/Library/Caches", .file), "a standard Library folder itself refused")
ok(safe(F + "/Library/SomeAppFolder", .file), "a non-standard folder directly in Library allowed")
ok(!safe(F + "/Library/Caches/linkout", .file), "link pointing elsewhere refused")
ok(safe(F + "/bin/foo", .file), "command-line link into an app allowed")
ok(safe(F + "/Applications/Foo 2024", .file), "wrapper folder holding an app allowed")
ok(!safe(F + "/Applications", .file), "Applications itself refused")
ok(!safe("/etc/hosts", .admin), "/etc/hosts refused")
ok(!safe("/Library/Application Support/Apple/x", .admin), "inside Apple's folder refused")
ok(!safe("/Library/Caches", .admin), "standard /Library folder refused")
ok(!safe("/Applications/Safari.app", .admin), "Safari refused")
ok(!safe("/System/Applications/Calculator.app", .admin), "system app refused")
ok(!safe("/Applications/Utilities", .admin), "Utilities folder refused")
ok(!safe("/Applications/Crumbs.app", .app), "Crumbs won't remove itself")
ok(Scanner.withoutNested([FoundItem(url: URL(fileURLWithPath: "/a/b"), kind: .file, confidence: .sure),
                          FoundItem(url: URL(fileURLWithPath: "/a/b/c"), kind: .file, confidence: .sure)]).count == 1, "item inside a chosen folder is dropped")
// trashing a link moves only the link
let link = URL(fileURLWithPath: F + "/Library/Caches/com.zz.link")
var out: NSURL?; try! fm.trashItem(at: link, resultingItemURL: &out)
ok(fm.fileExists(atPath: F + "/target/keep.txt"), "trashing a link keeps what it points to")
print("TRASHED:" + (out?.path ?? ""))
