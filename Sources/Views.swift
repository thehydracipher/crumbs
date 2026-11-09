// Views.swift - the main window's views.
// Part of Crumbs. MIT License.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            Group {
                if model.showingOrphans {
                    OrphansView()
                } else if let app = model.current {
                    DetailView(app: app)
                } else {
                    DropHint(targeted: model.dropTargeted, notice: model.notice)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { HelpLinks().padding(.bottom, 14) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // Dragging an app over the window while something else is showing
                if model.dropTargeted && model.selectedID != Model.homeID { DropOverlay() }
            }
            .onExitCommand { model.goHome() }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if model.update != nil && !model.updateHidden || model.updateStatus != nil { UpdateBanner() }
                    if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search apps or bundle ID")
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let app = TargetApp.load(url) else { return }
                Task { @MainActor in model.open(app) }
            }
            return true
        }
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            if let status = model.updateStatus {
                ProgressView().controlSize(.small)
                Text(status).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            } else if let r = model.update {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Crumbs \(r.version) is available.").font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("What's New") { NSWorkspace.shared.open(r.page) }.glassButton()
                Button("Later") { model.updateHidden = true }.glassButton()
                Button("Update Now") { Task { await model.installUpdate() } }.glassButton(prominent: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 16, tint: .accentColor.opacity(0.18))
    }
}

struct FullDiskAccessBanner: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Crumbs needs Full Disk Access to find every leftover and to undo.").font(.callout)
                Text("Already on? Remove Crumbs with − and add it again (needed after each update).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings") { model.openFullDiskAccessSettings() }.glassButton()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 16, tint: .orange.opacity(0.18))
        .help("Without it, macOS hides some Library folders from Crumbs and protects the Trash, so Undo can't move files back. This disappears by itself once access is on.")
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        List(selection: $model.selectedID) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(Model.homeID)
                    .help("Back to the start: drop an app here (or press Esc)")
                Label("Orphaned Files", systemImage: "questionmark.folder")
                    .tag(Model.orphansID)
                    .help("Leftovers from apps that are no longer installed")
            }
            Section("Apps") {
                if let bid = model.searchAsBundleID, model.filteredApps.isEmpty {
                    Button {
                        model.open(TargetApp.byBundleID(bid))
                    } label: {
                        Label("Find leftovers of \(bid)", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.link)
                    .padding(.vertical, 4)
                }
                ForEach(model.filteredApps) { app in SidebarRow(app: app) }
            }
            if !model.filteredPlugins.isEmpty {
                Section("Plug-ins & Widgets") {
                    ForEach(model.filteredPlugins) { app in SidebarRow(app: app, showType: true) }
                }
            }
        }
        .overlay {
            if model.apps.isEmpty { ProgressView() }
        }
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look again: reload apps and rescan")
            }
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: Model
    let app: TargetApp
    var showType = false

    var body: some View {
        let userProtected = model.isUserProtected(app)
        HStack(spacing: 8) {
            AppIcon(url: app.url, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.displayName).lineLimit(1)
                if showType { Text(app.typeLabel).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if app.isProtected || userProtected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                    .help(app.protectionReason ?? "Protected")
            } else if app.url == nil {
                Text("deleted").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(app.id)
        .contextMenu {
            if !app.bundleID.lowercased().hasPrefix("com.apple.") {
                Button(userProtected ? "Allow Removal" : "Protect from Removal") { model.setProtected(app, !userProtected) }
            }
            if let u = app.url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Drop to scan this app").font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 28, tint: .accentColor.opacity(0.22))
        .padding(24)
        .allowsHitTesting(false)
    }
}

struct DropHint: View {
    var targeted: Bool
    var notice: String? = nil
    var body: some View {
        VStack(spacing: 14) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassCapsule(tint: .green.opacity(0.12))
                    .padding(.bottom, 6)
            }
            Image(systemName: targeted ? "arrow.down.app.fill" : "sparkles")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(targeted ? "Drop it here" : "Welcome to Crumbs").font(.title2.weight(.semibold))
            Text("Pick an app on the left, or drag one here.\nCrumbs shows what it left behind. You choose what goes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(44)
        .glassCard(cornerRadius: 28, tint: targeted ? .accentColor.opacity(0.25) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.25))
        )
        .padding(40)
    }
}

/// Small links under the welcome screen, so "Report a Problem" is easy to find.
struct HelpLinks: View {
    var body: some View {
        HStack(spacing: 18) {
            Button { NSWorkspace.shared.open(Updater.reportProblemURL()) } label: {
                Label("Report a Problem", systemImage: "ladybug")
            }
            Button { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/issues/new?template=idea.yml")!) } label: {
                Label("Suggest an Idea", systemImage: "lightbulb")
            }
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}

// MARK: - One app

struct DetailView: View {
    @EnvironmentObject var model: Model
    let app: TargetApp

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            if let cask = model.homebrewCask {
                Banner(icon: "mug", text: "Homebrew installed this app. After removing it, also run:  brew uninstall --cask \(cask)")
            }
            Divider()
            if let reason = app.protectionReason {
                VStack(spacing: 12) {
                    CenterMessage(icon: app.isCrumbs ? "sparkles" : "lock.fill", title: reason,
                                  sub: app.isCrumbs ? "To remove Crumbs, choose Crumbs → Uninstall Crumbs… in the menu bar."
                                                    : "Crumbs won't remove protected apps.")
                    if app.isCrumbs {
                        Button("Uninstall Crumbs…") { model.uninstallCrumbs() }.glassButton()
                    }
                    if model.isUserProtected(app) {
                        Button("Allow Removal") { model.setProtected(app, false) }.glassButton()
                    }
                    Spacer()
                }
            } else if model.scanning {
                ProgressView("Looking…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                CenterMessage(icon: "checkmark.circle", title: "Nothing left behind.", sub: model.notice ?? "This app is already clean.")
                if !model.lastMoved.isEmpty {
                    Button("Undo") { model.undoLastMove() }.glassButton().frame(maxWidth: .infinity).padding(.bottom, 30)
                }
            } else {
                itemList
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TrashFooter(runningName: app.isApp ? app.displayName : nil)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .glassCard(cornerRadius: 22)
                            .padding(12)
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(url: app.url, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).font(.title2.weight(.semibold))
                Text([app.isApp ? nil : app.typeLabel, app.bundleID, app.version.map { "version \($0)" },
                      app.url == nil ? "already deleted" : nil]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var itemList: some View {
        List {
            itemSection(model.userItems, title: "In your Library")
            itemSection(model.adminItems, title: "System files (asks for your password)")
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func itemSection(_ list: [FoundItem], title: String) -> some View {
        if !list.isEmpty {
            let allOn = list.allSatisfy { model.checked.contains($0.id) }
            Section {
                ForEach(list) { item in ItemRow(item: item, checked: model.binding(for: item)) }
            } header: {
                HStack {
                    Text("\(title) · \(list.count)")
                    Spacer()
                    Button(allOn ? "Select none" : "Select all") { model.setChecked(list.map(\.id), !allOn) }
                        .buttonStyle(.link).font(.caption)
                }
            } footer: {
                if list.contains(where: { $0.confidence == .possible }) {
                    Text("\"Possible\" items only look similar to this app, so they are not ticked. Check them before you tick them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Orphans

struct OrphansView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "questionmark.folder.fill")
                    .font(.system(size: 34)).foregroundStyle(.tint).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Orphaned Files").font(.title2.weight(.semibold))
                    Text("Files from apps that are no longer installed. Nothing is ticked: check each one first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.rescan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .glassButton().disabled(model.scanning)
            }
            .padding(20)
            Divider()
            if model.scanning {
                ProgressView("Looking for orphaned files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                CenterMessage(icon: "checkmark.circle", title: "No orphaned files found.",
                              sub: model.notice ?? "Nothing left over from deleted apps.")
                if !model.lastMoved.isEmpty {
                    Button("Undo") { model.undoLastMove() }.glassButton().frame(maxWidth: .infinity).padding(.bottom, 30)
                }
            } else {
                List {
                    ForEach(model.orphanGroups, id: \.id) { group in
                        let ids = group.items.map(\.id)
                        let on = ids.allSatisfy { model.checked.contains($0) }
                        Section {
                            ForEach(group.items) { item in ItemRow(item: item, checked: model.binding(for: item), showBadge: false) }
                        } header: {
                            HStack {
                                Toggle(isOn: Binding(get: { on }, set: { model.setChecked(ids, $0) })) {
                                    Text(group.id).font(.headline).textSelection(.enabled)
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                Text(Scanner.prettySize(group.items.contains { $0.size < 0 } ? -1 : group.items.reduce(0) { $0 + $1.size }))
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TrashFooter(runningName: nil)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .glassCard(cornerRadius: 22)
                        .padding(12)
                }
            }
        }
    }
}

// MARK: - Shared pieces

struct TrashFooter: View {
    @EnvironmentObject var model: Model
    let runningName: String?

    var body: some View {
        HStack(spacing: 12) {
            if model.working {
                ProgressView().controlSize(.small)
                Text(model.selectedNeedsPassword ? "Waiting for your password…" : "Moving…").font(.callout).foregroundStyle(.secondary)
            } else if let name = runningName, model.isRunning {
                Label("\(name) is running.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                if model.offerForceQuit {
                    Button("Force Quit") { model.forceQuitCurrentApp() }.glassButton()
                        .help("The app didn't quit. This closes it without saving.")
                } else {
                    Button(model.quitting ? "Quitting…" : "Quit \(name)") { model.quitCurrentApp() }.glassButton()
                        .disabled(model.quitting)
                }
            } else if let n = model.notice {
                Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                if model.needsAppManagement { Button("Open Settings") { model.openAppManagementSettings() }.glassButton() }
                else if !model.hasFullDiskAccess && !model.lastMoved.isEmpty { Button("Open Settings") { model.openFullDiskAccessSettings() }.glassButton() }
                if !model.lastMoved.isEmpty { Button("Undo") { model.undoLastMove() }.glassButton() }
            }
            Spacer()
            Text("\(model.selectedItems.count) selected · \(Scanner.prettySize(model.selectedSize))\(model.sizesPending ? "+" : "")")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button(model.selectedNeedsPassword ? "Move to Trash…" : "Move to Trash", role: .destructive) { model.confirming = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .glassButton(prominent: true)
                .disabled(model.selectedItems.isEmpty || model.working || (runningName != nil && model.isRunning))
        }
        .confirmationDialog("Move \(model.selectedItems.count) item(s) to the Trash?",
                            isPresented: $model.confirming) {
            Button("Move to Trash", role: .destructive) { model.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    private var confirmText: String {
        var s = "\(Scanner.prettySize(model.selectedSize)) will go to the Trash. You can undo this until you empty the Trash"
            + (model.hasFullDiskAccess ? "." : " (Undo needs Full Disk Access).")
        if model.selectedHasUserData { s += "\n\nSome of these folders hold your own data for this app (settings, documents, history)." }
        if model.selectedNeedsPassword { s += "\n\nSystem files need your Mac password. macOS will ask for it." }
        return s
    }
}

extension Model {
    func binding(for item: FoundItem) -> Binding<Bool> {
        Binding(get: { self.checked.contains(item.id) },
                set: { self.setChecked([item.id], $0) })
    }
}

struct ItemRow: View {
    let item: FoundItem
    let checked: Binding<Bool>?
    var showBadge = true

    var body: some View {
        HStack(spacing: 10) {
            if let checked {
                Toggle("", isOn: checked).labelsHidden().toggleStyle(.checkbox)
            }
            Image(nsImage: IconCache.icon(item.url.path))
                .resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(Scanner.shortPath(item.url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.isUserData { Chip(text: "Your data", color: .purple, tip: "This folder may hold your settings, documents or history for this app.") }
            if item.kind.needsAdmin { Chip(text: "Admin", color: .gray, tip: "A system file. macOS will ask for your password.") }
            if showBadge { ConfidenceBadge(confidence: item.confidence) }
            Text(Scanner.prettySize(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}

struct Chip: View {
    let text: String, color: Color, tip: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .glassCapsule(tint: color.opacity(0.16))
            .help(tip)
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence
    static let tip = ["Only looks similar. Check before trashing.",     // possible
                      "Has exactly this app's name.",                     // likely
                      "Matches this app's bundle ID or signature."]       // sure
    static let colors: [Color] = [.orange, .blue, .green]
    var body: some View {
        Chip(text: confidence.label, color: Self.colors[confidence.rawValue], tip: Self.tip[confidence.rawValue])
    }
}

struct Banner: View {
    let icon: String, text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout).textSelection(.enabled)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
    }
}

struct CenterMessage: View {
    let icon: String, title: String, sub: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(sub).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppIcon: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        let img: NSImage = url.map { IconCache.icon($0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        Image(nsImage: img).resizable().frame(width: size, height: size)
    }
}

/// Icons are slow to look up; remember them so long lists scroll smoothly.
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(_ path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

// MARK: - Liquid Glass (macOS 26+), with the classic look on older macOS

extension View {
    /// A floating glass panel.
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background((tint ?? .clear).opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// A small glass pill (used for labels).
    @ViewBuilder func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .capsule)
        } else {
            self.background((tint ?? .clear), in: Capsule())
        }
    }

    /// Glass buttons; the main action is a tinted ("prominent") glass button.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}
