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
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                if model.showingOrphans {
                    OrphansView()
                } else if let app = model.current {
                    DetailView(app: app)
                } else {
                    DropHint(targeted: model.dropTargeted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        List(selection: $model.selectedID) {
            Section {
                Label("Orphaned Files", systemImage: "questionmark.folder")
                    .tag(Model.orphansID)
                    .help("Crumbs from apps that are no longer installed")
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
                ForEach(model.filteredApps) { app in
                    HStack(spacing: 8) {
                        AppIcon(url: app.url, size: 22)
                        Text(app.displayName).lineLimit(1)
                        Spacer(minLength: 0)
                        if app.isProtected {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                                .help("Built-in Apple app")
                        } else if app.url == nil {
                            Text("deleted").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(app.id)
                }
            }
        }
        .overlay {
            if model.apps.isEmpty { ProgressView() }
        }
        .toolbar {
            ToolbarItem {
                Button { model.reloadApps() } label: { Label("Reload apps", systemImage: "arrow.clockwise") }
                    .help("Reload the app list")
            }
        }
    }
}

struct DropHint: View {
    var targeted: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop an app here").font(.title2.weight(.semibold))
            Text("Or pick one on the left.\nCrumbs lists the files it left behind, and you choose what goes to the Trash.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .padding(40)
    }
}

// MARK: - One app

struct DetailView: View {
    @EnvironmentObject var model: Model
    let app: TargetApp

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            if app.isProtected {
                CenterMessage(icon: "lock.fill", title: "This is a built-in Apple app.", sub: "Crumbs never touches these.")
            } else if model.scanning {
                ProgressView("Looking…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                CenterMessage(icon: "checkmark.circle", title: "Nothing left behind.", sub: model.notice ?? "This app is already clean.")
            } else {
                itemList
                Divider()
                TrashFooter(runningName: app.displayName).padding(16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(url: app.url, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).font(.title2.weight(.semibold))
                Text([app.bundleID, app.version.map { "version \($0)" }, app.url == nil ? "app already deleted" : nil]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var itemList: some View {
        let all = model.trashableItems
        let allOn = model.selectedItems.count == all.count
        return List {
            Section {
                ForEach(all) { item in ItemRow(item: item, checked: model.binding(for: item)) }
            } header: {
                HStack {
                    Text("Found \(all.count) item\(all.count == 1 ? "" : "s")")
                    Spacer()
                    Button(allOn ? "Select none" : "Select all") { model.setChecked(all.map(\.id), !allOn) }
                        .buttonStyle(.link).font(.caption)
                }
            } footer: {
                if all.contains(where: { $0.confidence == .possible }) {
                    Text("\"Possible\" items only look similar to this app, so they are not ticked. Check them before you tick them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.otherItems.isEmpty {
                Section("System files (need an admin password, remove by hand)") {
                    ForEach(model.otherItems) { item in ItemRow(item: item, checked: nil) }
                }
            }
        }
        .listStyle(.inset)
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
                    .disabled(model.scanning)
            }
            .padding(20)
            Divider()
            if model.scanning {
                ProgressView("Looking for orphaned files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                CenterMessage(icon: "checkmark.circle", title: "No orphaned files found.",
                              sub: model.notice ?? "Nothing left over from deleted apps.")
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
                                Text(Scanner.prettySize(group.items.reduce(0) { $0 + $1.size }))
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                Divider()
                TrashFooter(runningName: nil).padding(16)
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
            if let name = runningName, model.isRunning {
                Label("\(name) is running.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                if model.offerForceQuit {
                    Button("Force Quit") { model.forceQuitCurrentApp() }
                        .help("The app didn't quit. This closes it without saving.")
                } else {
                    Button(model.quitting ? "Quitting…" : "Quit \(name)") { model.quitCurrentApp() }
                        .disabled(model.quitting)
                }
            } else if let n = model.notice {
                Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text("\(model.selectedItems.count) selected · \(Scanner.prettySize(model.selectedSize))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button("Move to Trash", role: .destructive) { model.confirming = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedItems.isEmpty || (runningName != nil && model.isRunning))
        }
        .confirmationDialog("Move \(model.selectedItems.count) item(s) to the Trash?",
                            isPresented: $model.confirming) {
            Button("Move to Trash", role: .destructive) { model.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Scanner.prettySize(model.selectedSize)) will go to the Trash. You can put them back until you empty it.")
        }
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
            } else {
                Image(systemName: item.kind == .receipt ? "doc.text" : "lock")
                    .foregroundStyle(.secondary).frame(width: 16)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(Scanner.shortPath(item.url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if showBadge, item.kind.trashable { ConfidenceBadge(confidence: item.confidence) }
            if item.kind != .receipt {
                Text(Scanner.prettySize(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
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

struct ConfidenceBadge: View {
    let confidence: Confidence
    static let tip = ["Only looks similar. Check before trashing.",     // possible
                      "Has exactly this app's name.",                     // likely
                      "Matches this app's bundle ID or signature."]       // sure
    var body: some View {
        let color: Color = switch confidence {
            case .sure: .green
            case .likely: .blue
            case .possible: .orange
        }
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .help(Self.tip[confidence.rawValue])
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
        let img: NSImage = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        Image(nsImage: img).resizable().frame(width: size, height: size)
    }
}
