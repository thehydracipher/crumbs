// Updater: refuses bad downloads. Needs internet (skipped if offline). Changes nothing.
import Foundation
func ok(_ c: Bool, _ w: String) { print((c ? "PASS " : "FAIL ") + w) }
ok(Updater.isNewer("1.10", than: "1.9") && !Updater.isNewer("1.2", than: "1.2") && Updater.isNewer("2", than: "1.9.9"), "version comparison")
let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    guard let real = try? await Updater.latest() else { print("SKIP offline"); return }
    ok(real.sha256?.count == 64, "GitHub publishes a SHA-256 checksum for the download")
    let badSum = Release(version: real.version, notes: "", page: real.page, zip: real.zip, sha256: String(repeating: "0", count: 64))
    do { _ = try await Updater.download(badSum); ok(false, "wrong checksum refused") }
    catch { ok((error as? UpdateError).map { if case .checksum = $0 { return true } else { return false } } ?? false, "wrong checksum refused") }
    let badVersion = Release(version: "99.0", notes: "", page: real.page, zip: real.zip, sha256: real.sha256)
    do { _ = try await Updater.download(badVersion); ok(false, "download that isn't the promised version refused") }
    catch { ok((error as? UpdateError).map { if case .notCrumbs = $0 { return true } else { return false } } ?? false, "download that isn't the promised version refused") }
    if let good = try? await Updater.download(real) {
        ok(FileManager.default.fileExists(atPath: good.appendingPathComponent("Contents/MacOS/Crumbs").path), "the real download is accepted")
        try? FileManager.default.removeItem(at: good.deletingLastPathComponent())
    } else { ok(false, "the real download is accepted") }
}
sem.wait()
