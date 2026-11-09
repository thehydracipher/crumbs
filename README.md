# Crumbs

A small, free, open-source Mac app that removes an app **and** the files it leaves behind.

- Drop an app on the window, or pick it from the list.
- See every leftover file, with its size.
- Untick anything you want to keep.
- Click **Move to Trash**. Nothing is deleted for good. **Undo** (⌘Z) puts it all back.

Works for apps **and** plug-ins: preference panes, screen savers, Quick Look,
Spotlight, audio plug-ins (AU/VST/VST3), widgets and more.

## Why it's fast

It doesn't walk your whole disk. It looks in the places macOS apps actually use
(about 40 folders in your Library and the system Library) and matches by the app's
bundle ID and name. A scan usually takes a fraction of a second.

## What it finds

- Settings, caches, logs, saved window state, cookies and web data
- Sandbox containers and shared group folders (read from the app's own signature)
- Crash reports, recent-file lists, plug-ins, autosaves, scripts and audio presets
- macOS's hidden per-app cache and temp folders (`/var/folders/…`)
- Folders with version endings, like `Name 2` or `Name Beta`
- System files in `/Library` (launch daemons, helper tools, receipts…). These need your
  Mac password: macOS asks once, in its own window. Crumbs never sees the password.
- If Homebrew installed the app, it tells you the `brew uninstall --cask` command too.

## Match levels

Every file gets a label:

- **Sure**: matches the app's bundle ID, or the app's own signature names it.
- **Likely**: a folder with exactly the app's name.
- **Possible**: only looks similar (like `Name 2` or `NameBeta`). Never ticked for you.

## Orphaned files

**Orphaned Files** (top of the sidebar, or ⇧⌘O) lists files from apps that are no longer
installed. Nothing is ticked: check each one first. It skips Apple files, files from
vendors you still have an app from, and shared code libraries (like Firebase or Sentry).

## Watch for deleted apps

While this is on (the default), Crumbs sits in the menu bar (no Dock icon once you close the window). When you drag an app to
the Trash in Finder, it pops up with what that app left behind. Turn it off, or turn on
**Open at login**, from the menu bar icon or Settings (⌘,).

## Safety

- Built-in Apple apps, and anything macOS locks (System Integrity Protection), are never touched.
- **Protected apps**: right-click an app and choose *Protect from Removal* (manage them in Settings).
- Folders that may hold your own data are marked **Your data**, and the confirm box warns you.
- If the app is running, a **Quit** button appears (and **Force Quit** if it won't close).
- Every item is checked again right before it moves: only app bundles and files inside a
  sub-folder of `~/Library` are allowed. Links that point outside are refused.
- Background helpers (LaunchAgents) are stopped before their files are trashed.
- Short or generic app names (like "Data") are matched by bundle ID only, so other apps' files are safe.

## Build

You only need Apple's free Command Line Tools (`xcode-select --install`).

```bash
./build.sh
cp -R build/Crumbs.app /Applications/
```

Needs macOS 14 or later.

## Command line

The same scanner works from Terminal:

```bash
build/Crumbs.app/Contents/MacOS/Crumbs --scan "Sublime Text"
build/Crumbs.app/Contents/MacOS/Crumbs --trash "Sublime Text"   # skips "possible" items
build/Crumbs.app/Contents/MacOS/Crumbs --trash "Sublime Text" --include-possible
build/Crumbs.app/Contents/MacOS/Crumbs --orphans
```

Debug the watcher with `CRUMBS_DEBUG=1`.

## Tip

To see inside other apps' sandbox folders, macOS may ask you to give Crumbs
**Full Disk Access** (System Settings → Privacy & Security).

## License

MIT. See `LICENSE`.
