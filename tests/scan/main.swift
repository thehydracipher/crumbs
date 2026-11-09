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
print("scan took \(ms) ms")
