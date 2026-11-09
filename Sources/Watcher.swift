// Watcher.swift - notices when an app is removed from Applications,
// so Crumbs can offer to clean up what it left behind.
// Part of Crumbs. MIT License.

import Foundation
import CoreServices

/// Set CRUMBS_DEBUG=1 to see what the watcher is doing.
private func debug(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["CRUMBS_DEBUG"] != nil { FileHandle.standardError.write(("[watch] " + s() + "\n").data(using: .utf8)!) }
}

final class AppWatcher {
    private var stream: FSEventStreamRef?
    private var snapshot: [String: TargetApp] = [:]      // app path -> app
    private var pending: DispatchWorkItem?
    private let onRemoved: (TargetApp) -> Void

    init(onRemoved: @escaping (TargetApp) -> Void) {
        self.onRemoved = onRemoved
        snapshot = Self.currentApps()
        start()
        debug("started, \(snapshot.count) apps")
    }

    deinit { stop() }

    func stop() {
        pending?.cancel()
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
    }

    private static func currentApps() -> [String: TargetApp] {
        var d: [String: TargetApp] = [:]
        for a in Scanner.installedApps() { if let p = a.url?.path { d[p] = a } }
        return d
    }

    /// Uses FSEvents (handles /Applications being a special "firmlink" on modern macOS).
    private func start() {
        let paths = ["/Applications", Scanner.home.appendingPathComponent("Applications").path]
            .filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          1.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// Wait a few seconds before checking: app updaters remove and re-add an app quickly.
    private func schedule() {
        debug("folder changed")
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func check() {
        let now = Self.currentApps()
        let removed = snapshot.filter { now[$0.key] == nil }.map(\.value)
        debug("check: \(now.count) apps, removed \(removed.map(\.displayName))")
        snapshot = now
        for app in removed {
            guard let p = app.url?.path, !FileManager.default.fileExists(atPath: p),
                  !Scanner.isInstalledAnywhere(app.bundleID)
            else { debug("ignored \(app.displayName) (still installed somewhere)"); continue }
            debug("removed: \(app.displayName)")
            onRemoved(app)
        }
    }
}
