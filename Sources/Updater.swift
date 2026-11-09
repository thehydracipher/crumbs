// Updater.swift - checks GitHub for a newer Crumbs and installs it with one click.
// The only time Crumbs goes online. It sends nothing about you: just a normal request for the latest release.
// Part of Crumbs. MIT License.

import Foundation
import CryptoKit

struct Release: Sendable {
    let version: String     // e.g. "1.4"
    let notes: String
    let page: URL           // the release page on GitHub
    let zip: URL            // Crumbs-x.y.zip
    let sha256: String?     // checksum GitHub publishes for the file
}

enum UpdateError: LocalizedError {
    case network(String), noDownload, checksum, notCrumbs, cantReplace(String)
    var errorDescription: String? {
        switch self {
        case .network(let s): return "Couldn't reach GitHub (\(s))."
        case .noDownload: return "The new version has no download yet."
        case .checksum: return "The download didn't match its checksum, so it wasn't installed."
        case .notCrumbs: return "The download isn't a valid Crumbs app, so it wasn't installed."
        case .cantReplace(let s): return "Couldn't replace Crumbs: \(s)"
        }
    }
}

enum Updater {
    static let repo = "thehydracipher/crumbs"
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "1.10" is newer than "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The latest published release on GitHub.
    static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Crumbs/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw UpdateError.network(error.localizedDescription) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.network("unexpected answer") }
        let assets = j["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String).map { $0.hasPrefix("Crumbs") && $0.hasSuffix(".zip") } ?? false }),
              let url = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)),
              url.host == "github.com" || url.host?.hasSuffix(".githubusercontent.com") == true
        else { throw UpdateError.noDownload }
        let digest = (zip["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: j["body"] as? String ?? "",
                       page: page, zip: url, sha256: digest)
    }

    /// Downloads and checks the new app. Returns the new Crumbs.app in a temporary folder.
    static func download(_ r: Release) async throws -> URL {
        let tmp: URL
        do { (tmp, _) = try await URLSession.shared.download(from: r.zip) } catch { throw UpdateError.network(error.localizedDescription) }
        // 1. The file must match the checksum GitHub publishes for it.
        if let want = r.sha256 {
            let have = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
            guard have == want else { throw UpdateError.checksum }
        }
        // 2. Unzip into a fresh private folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crumbs-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", tmp.path, dir.path]) == 0 else { throw UpdateError.notCrumbs }
        let app = dir.appendingPathComponent("Crumbs.app")
        // 3. It must be Crumbs, the version promised, and its code signature must be intact.
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? Scanner.myBundleID,
              info["CFBundleShortVersionString"] as? String == r.version,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
        else { throw UpdateError.notCrumbs }
        return app
    }

    /// Replaces the running Crumbs with the new one, then opens it again.
    /// A tiny helper waits for Crumbs to quit, swaps the apps (keeping the old one until the new one is in place),
    /// and starts the new version.
    static func install(_ newApp: URL, relaunch: Bool = true) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.cantReplace("Crumbs isn't running from an app bundle.") }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
        else { throw UpdateError.cantReplace("no permission to change \(target.deletingLastPathComponent().path).") }
        let q = Admin.q
        let backup = target.deletingLastPathComponent().appendingPathComponent(".Crumbs-old-\(UUID().uuidString).app")
        let script = """
        while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/mv \(q(target.path)) \(q(backup.path)) || exit 1
        if /usr/bin/ditto \(q(newApp.path)) \(q(target.path)); then /bin/rm -rf \(q(backup.path))
        else /bin/rm -rf \(q(target.path)); /bin/mv \(q(backup.path)) \(q(target.path)); fi
        /bin/rm -rf \(q(newApp.deletingLastPathComponent().path))
        \(relaunch ? "/usr/bin/open \(q(target.path))" : "true")
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateError.cantReplace(error.localizedDescription) }
    }

    /// Opens a ready-made GitHub bug report with the basics filled in (nothing is sent until you submit it).
    static func reportProblemURL() -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var arm: Int32 = 0; var size = MemoryLayout<Int32>.size
        let appleSilicon = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: currentVersion),
            URLQueryItem(name: "macos", value: "macOS \(os.majorVersion).\(os.minorVersion)"),
            URLQueryItem(name: "mac", value: appleSilicon ? "Apple silicon (M1, M2, M3, M4…)" : "Intel"),
            URLQueryItem(name: "fda", value: Scanner.hasFullDiskAccess() ? "Yes" : "No"),
        ]
        return c.url!
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
}
