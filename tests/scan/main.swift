// Scanner: matching rules on a fake home folder.
import Foundation
let W = CommandLine.arguments[1]; let F = W + "/home"; let fm = FileManager.default
func ok(_ c: Bool, _ w: String) { print((c ? "PASS " : "FAIL ") + w) }
func mk(_ p: String) { try! fm.createDirectory(atPath: F + "/" + p, withIntermediateDirectories: true) }
func touch(_ p: String) { mk((p as NSString).deletingLastPathComponent); fm.createFile(atPath: F + "/" + p, contents: Data()) }
func plist(_ path: String, _ d: [String: Any]) { mk((path as NSString).deletingLastPathComponent)
    try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: URL(fileURLWithPath: F + "/" + path)) }
// App "Testy Widget 5" (file name Testy.app) with a login-item helper and a shared updater
plist("Applications/Testy Suite 2026/Testy.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.testy", "CFBundleName": "Testy Widget 5",
      "CFBundleExecutable": "testyd", "SMPrivilegedExecutables": ["com.example.testyroot": "x"]])
plist("Applications/Testy Suite 2026/Testy.app/Contents/Library/LoginItems/Helper.app/Contents/Info.plist", ["CFBundleIdentifier": "com.othervendor.loginhelper"])
plist("Applications/Testy Suite 2026/Testy.app/Contents/Frameworks/Updater.app/Contents/Info.plist", ["CFBundleIdentifier": "com.shared.updater"])
plist("Applications/Other.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.other", "CFBundleName": "Other"])
plist("Applications/Other.app/Contents/Frameworks/Updater.app/Contents/Info.plist", ["CFBundleIdentifier": "com.shared.updater"])
for f in ["Library/Preferences/com.example.testy.plist", "Library/Preferences/com.example.testyplus.plist",
          "Library/Preferences/com.othervendor.loginhelper.plist", "Library/Preferences/com.shared.updater.plist",
          "Library/SyncedPreferences/com.example.testy.plist", "Library/Logs/DiagnosticReports/testyd-2026-01-01.ips",
          "Library/Application Support/CrashReporter/testyd_ABC.plist", "Library/LaunchAgents/com.example.testyroot.plist"] { touch(f) }
for d in ["Library/Application Support/Testy Widget 5", "Library/Application Support/Testy Widget", "Library/Caches/Testy",
          "Library/Testy Widget 5", "Library/Caches/com.apple.helpd/Generated/com.example.testy", "Library/Application Support/Testy Widgetron",
          "Library/Containers/12345678-1234-1234-1234-123456789ABC", "Library/Application Support/MakerCo/Testy Widget 5"] { mk(d) }
plist("Library/Containers/12345678-1234-1234-1234-123456789ABC/.com.apple.containermanagerd.metadata.plist", ["MCMMetadataIdentifier": "com.example.testy"])
for f in ["Downloads/Testy-Widget-5.2-arm64.dmg", "Downloads/TestyWidget5_Installer.pkg", "Downloads/Other-1.0.dmg",
          "Downloads/testy widget 5 notes.txt"] { touch(f) }
// A separate installed app whose ID starts with Testy's ID (like Chrome and Chrome Canary), and prefix-like IDs
plist("Applications/Sibling.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.testy.canary", "CFBundleName": "Sibling"])
plist("Applications/Short.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example", "CFBundleName": "Shorty"])
plist("Applications/Tiny.app/Contents/Info.plist", ["CFBundleIdentifier": "com", "CFBundleName": "Tinyapp"])
for f in ["Library/Preferences/com.example.testy.canary.plist", "Library/Preferences/com.example.plist"] { touch(f) }
for d in ["Library/Caches/com.example.testy.canary", "Library/Caches/com.example.testy.ShipIt",
          "Library/Group Containers/group.com.example.testy.canary", "Library/Group Containers/group.com.example.testy"] { mk(d) }
let app = TargetApp.load(URL(fileURLWithPath: F + "/Applications/Testy Suite 2026/Testy.app"))!
let t0 = Date(); let items = Scanner.scan(app); let ms = Int(Date().timeIntervalSince(t0) * 1000)
func conf(_ rel: String) -> Confidence? { items.first { $0.url.path == F + "/" + rel }?.confidence }
ok(conf("Library/Preferences/com.example.testy.plist") == .sure, "settings by bundle ID: sure")
ok(conf("Library/Preferences/com.example.testyplus.plist") == nil, "look-alike ID com.example.testyplus NOT matched (AppCleaner would)")
ok(conf("Library/Preferences/com.othervendor.loginhelper.plist") == .likely, "helper inside the app with its own ID: likely")
ok(conf("Library/Preferences/com.shared.updater.plist") == .possible, "helper SHARED with another installed app: only possible")
ok(conf("Library/LaunchAgents/com.example.testyroot.plist") != nil, "root helper tool declared in Info.plist found")
ok(conf("Library/SyncedPreferences/com.example.testy.plist") == .sure, "SyncedPreferences found")
ok(conf("Library/Logs/DiagnosticReports/testyd-2026-01-01.ips") == .likely, "crash report by program name found")
ok(conf("Library/Application Support/CrashReporter/testyd_ABC.plist") == .likely, "CrashReporter file by program name found")
ok(conf("Library/Application Support/Testy Widget 5") == .likely, "exact name: likely")
ok(conf("Library/Application Support/Testy Widget") == .possible, "name without trailing number: only possible")
ok(conf("Library/Application Support/Testy Widgetron") == nil, "look-alike name NOT matched")
ok(conf("Library/Caches/Testy") == .likely, "app file name (Testy.app) used as a name")
ok(conf("Library/Testy Widget 5") == .likely, "folder directly in Library found")
ok(conf("Library/Caches/com.apple.helpd/Generated/com.example.testy") == .sure, "Help book cache found")
ok(conf("Library/Containers/12345678-1234-1234-1234-123456789ABC") == .sure, "sandbox folder with a random ID found")
ok(conf("Library/Application Support/MakerCo/Testy Widget 5") == .likely, "maker sub-folder found")
ok(conf("Applications/Testy Suite 2026") == .likely, "wrapper folder in Applications found")
ok(items.allSatisfy { !$0.url.path.contains("/Other.app") }, "the other app is never included")
ok(conf("Downloads/Testy-Widget-5.2-arm64.dmg") == .possible, "leftover installer in Downloads: possible")
ok(conf("Downloads/TestyWidget5_Installer.pkg") == .possible, "leftover .pkg installer in Downloads: possible")
ok(conf("Downloads/Other-1.0.dmg") == nil, "another app's installer NOT matched")
ok(conf("Downloads/testy widget 5 notes.txt") == nil, "a document in Downloads is never matched")
ok(Scanner.isSafeToTrash(FoundItem(url: URL(fileURLWithPath: F + "/Downloads/Testy-Widget-5.2-arm64.dmg"), kind: .file, confidence: .possible)),
   "installer in Downloads may be moved")
ok(!Scanner.isSafeToTrash(FoundItem(url: URL(fileURLWithPath: F + "/Downloads/testy widget 5 notes.txt"), kind: .file, confidence: .possible)),
   "a document in Downloads may NOT be moved")

ok(conf("Library/Preferences/com.example.testy.canary.plist") == nil, "another installed app's settings (ID starts with ours) NOT matched")
ok(conf("Library/Caches/com.example.testy.canary") == nil, "another installed app's cache (ID starts with ours) NOT matched")
ok(conf("Library/Group Containers/group.com.example.testy.canary") == nil, "another installed app's group folder NOT matched")
ok(conf("Library/Group Containers/group.com.example.testy") == .sure, "our own group folder still found")
ok(conf("Library/Caches/com.example.testy.ShipIt") == .sure, "our own ID with an extra ending still found")
let short = Scanner.scan(TargetApp.load(URL(fileURLWithPath: F + "/Applications/Short.app"))!, withSizes: false).map { $0.url.path }
ok(short.contains(F + "/Library/Preferences/com.example.plist"), "prefix-like ID (com.example): its exact settings file found")
ok(!short.contains { $0.contains("com.example.testy") || $0.contains("com.example.other") }, "prefix-like ID (com.example) does NOT claim other apps' files")
let tiny = Scanner.scan(TargetApp.load(URL(fileURLWithPath: F + "/Applications/Tiny.app"))!, withSizes: false).map { $0.url.path }
ok(!tiny.contains { $0.contains("/Library/Preferences/") || $0.contains("/Library/Caches/") || $0.contains("/Group Containers/") },
   "one-word ID (com) does NOT claim every com.* file")
ok(TargetApp(url: nil, bundleID: "com.apple", name: "x", version: nil).isProtected, "the ID com.apple itself is protected")

// Sizes must match macOS's du exactly
func du(_ p: String) -> Int64 {
    let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/du"); pr.arguments = ["-sk", p]
    let o = Pipe(); pr.standardOutput = o; try! pr.run(); pr.waitUntilExit()
    return Int64(String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.split(separator: "\t")[0])! * 1024
}
mk("Library/SizeTest/a/b/c"); for i in 0..<300 { fm.createFile(atPath: F + "/Library/SizeTest/a/b/c/f\(i)", contents: Data(repeating: 7, count: i * 37)) }
fm.createFile(atPath: F + "/Library/SizeTest/big", contents: Data(repeating: 1, count: 3_000_000))
ok(Scanner.size(of: URL(fileURLWithPath: F + "/Library/SizeTest")) == du(F + "/Library/SizeTest"), "folder size matches du exactly")

// A real mounted disk image: the .dmg an app runs from is found, the app itself is not moved
let dmg = W + "/CrumbsTest.dmg"
func run(_ a: [String]) -> String { let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); pr.arguments = a
    let o = Pipe(); pr.standardOutput = o; pr.standardError = Pipe(); try! pr.run(); pr.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
let srcDir = W + "/dmgsrc/DiskTesty.app/Contents"; try! fm.createDirectory(atPath: srcDir, withIntermediateDirectories: true)
try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.disktesty", "CFBundleName": "Disk Testy"], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: srcDir + "/Info.plist"))
_ = run(["create", "-quiet", "-srcfolder", W + "/dmgsrc", "-volname", "CrumbsDiskTest", "-format", "UDZO", dmg])
let attach = run(["attach", "-nobrowse", "-readonly", "-plist", dmg])
let mount = (try? PropertyListSerialization.propertyList(from: Data(attach.utf8), format: nil) as? [String: Any])?
    .flatMap { ($0["system-entities"] as? [[String: Any]])?.compactMap { $0["mount-point"] as? String }.first }
if let mount {
    let onDisk = TargetApp.load(URL(fileURLWithPath: mount + "/DiskTesty.app"))!
    let found = Scanner.scan(onDisk, withSizes: false)
    ok(found.contains { $0.url.resolvingSymlinksInPath().path == URL(fileURLWithPath: dmg).resolvingSymlinksInPath().path && $0.confidence == .possible },
       "the .dmg the app runs from is found (possible)")
    ok(!found.contains { $0.url.path.hasPrefix(mount) }, "the app on the read-only disk image is not listed")
    _ = run(["detach", "-quiet", mount])
} else { ok(false, "could not mount a test disk image") }
print("scan took \(ms) ms")
