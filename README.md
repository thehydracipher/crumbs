<p align="center">
  <img src="docs/images/icon-256.png" width="128" alt="Crumbs, the free app uninstaller for Mac and Windows">
</p>

<h1 align="center">Crumbs</h1>

<p align="center">
  <b>Uninstall apps completely.</b><br>
  Free and open source, for Mac and Windows.
</p>

<p align="center">
  <a href="https://github.com/thehydracipher/crumbs/releases/latest"><img src="https://img.shields.io/github/v/release/thehydracipher/crumbs?label=Download&color=6D28D9&style=for-the-badge" alt="Download the latest version"></a>
</p>

<p align="center">
  <img src="docs/images/screenshot.png" width="49%" alt="Crumbs on a Mac, showing an app and the files it would remove, each with a size and a label">
  <img src="docs/images/screenshot-windows.png" width="49%" alt="Crumbs on Windows, showing 7-Zip and the leftovers it found">
</p>

Crumbs is a free app uninstaller for Mac and Windows.
It removes an app and the files it leaves behind: settings, caches, logs and support files.

## Features

- Removes the app and its leftover files in one go.
- Shows every file and its size before anything is removed.
- Labels each file **Sure**, **Likely** or **Possible**. Files it isn't sure about are never ticked for you.
- Moves files to the Trash or Recycle Bin, with one-click **Undo**.
- Never touches the system, Apple or Microsoft apps, or your personal folders.
- Mac: finds leftovers from apps you deleted long ago, and notices when you delete an app in Finder.
- Updates itself. No ads, no account, no tracking.

## Install

**Mac** (macOS 14 or later, Apple silicon or Intel)

1. Download `Crumbs-x.y.zip` from [Releases](https://github.com/thehydracipher/crumbs/releases/latest).
2. Unzip it and drag Crumbs into Applications.
3. Open Crumbs. The first time, macOS blocks it: go to **System Settings → Privacy & Security** and click **Open Anyway**.
4. Turn on **Full Disk Access** when Crumbs asks. Without it, macOS hides some folders.

**Windows** (10 and 11)

1. Download `Windows-Crumbs-x.y-x64.zip` from [Releases](https://github.com/thehydracipher/crumbs/releases/latest). For ARM PCs, take the `arm64` one.
2. Unzip it and open `Crumbs.exe`. Nothing to install.
3. If Windows shows "Windows protected your PC", click **More info → Run anyway**.

## How to use

- **Mac:** pick an app, check the list, click **Move to Trash**.
- **Windows:** pick a program, click **Uninstall**, then **Clean up**.

## FAQ

**Is it free?**
Yes, and open source under the MIT license.

**Is it safe?**
Everything goes to the Trash or Recycle Bin first, and you can undo. Each file is checked again right before it moves.

**Why does my computer warn me the first time?**
Crumbs isn't sold through the App Store or Microsoft Store. You only confirm once.

**Does it send any data?**
No. It only contacts GitHub to check for a new version.

## Crumbs vs AppCleaner

|  | Crumbs | AppCleaner |
|---|:---:|:---:|
| Free | Yes | Yes |
| Open source | Yes | No |
| Undo | Yes | Yes |
| Shows how sure it is about each file | Yes | No |
| Finds leftovers of apps deleted long ago | Yes | No |
| Finds old installers in Downloads | Yes | No |
| Windows version | Yes | No |

## Report a problem

[Report a problem](https://github.com/thehydracipher/crumbs/issues/new?template=bug_report.yml) · [Suggest an idea](https://github.com/thehydracipher/crumbs/issues/new?template=idea.yml)

In the app: **Help → Report a Problem** on Mac, or the button at the bottom left on Windows.

<details>
<summary><b>For developers</b></summary>

### Mac (Swift, SwiftUI)

```bash
./build.sh                 # this Mac only
./build.sh universal       # Apple silicon + Intel
zsh tests/run.sh           # 69 checks on fake files, nothing real is touched
```

Command line: `Crumbs --scan "App"`, `--trash "App"`, `--orphans`, `--check-update`.

### Windows (C#, WPF, .NET 10)

The code is in `windows/`. GitHub Actions builds and tests it on Windows for every change.

```powershell
dotnet test windows/Tests
dotnet publish windows/App -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

### How it finds files

- **Sure:** the app's own ID, its install folder, its own shortcuts and start-up entries.
- **Likely:** the app's exact name, also inside the maker's folder; helpers inside the app; crash reports.
- **Possible:** similar names (`Name 2`, `NameBeta`), shared helpers, installers in Downloads.

### Safety

- Never removes: the system, Apple or Microsoft apps, Keychains, iCloud Drive, Mail, Messages, personal folders, folder links, or Crumbs itself.
- Every item is checked against a list of allowed places right before it moves.
- Mac system files move after one password prompt into a folder only the system can touch. Undo checks a SHA-256 fingerprint first.
- Windows registry entries are exported to a backup before removal.

### Updates

Crumbs checks the latest GitHub release once a day (you can turn this off), verifies the SHA-256 checksum, then replaces itself.

[![Mac tests](https://github.com/thehydracipher/crumbs/actions/workflows/tests.yml/badge.svg)](https://github.com/thehydracipher/crumbs/actions/workflows/tests.yml)
[![Windows tests](https://github.com/thehydracipher/crumbs/actions/workflows/windows.yml/badge.svg)](https://github.com/thehydracipher/crumbs/actions/workflows/windows.yml)

</details>

---

Crumbs is a free, open-source app uninstaller for macOS and Windows, and an alternative to AppCleaner, Pearcleaner, CleanMyMac and Revo Uninstaller. MIT License.
