// Scanner.cs - finds what a program leaves behind on Windows.
// Looks only in the known places, so it's fast. Same idea and labels as Crumbs for Mac.
// Part of Crumbs. MIT License.

using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Crumbs;

public static class Scanner
{
    /// Names too vague to match safely: these are only matched through the install folder.
    static readonly HashSet<string> Generic = new(StringComparer.OrdinalIgnoreCase)
    {
        "app", "apps", "data", "cache", "logs", "temp", "tmp", "update", "updater", "helper", "common", "shared",
        "microsoft", "windows", "google", "adobe", "intel", "nvidia", "amd", "programs", "packages", "tools",
        "setup", "installer", "launcher", "client", "service", "services", "software", "games", "user", "users",
    };

    /// "7-Zip 23.01 (x64 edition)" -> "7-Zip"
    public static string CleanName(string name)
    {
        var s = Regex.Replace(name, @"\s*\((x64|x86|64-bit|32-bit|arm64|[^)]*edition|[^)]*version)[^)]*\)", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"\s+(x64|x86|64-bit|32-bit)$", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"\s+v?\d+(\.\d+)*[a-z]?$", "", RegexOptions.IgnoreCase);
        return s.Trim();
    }

    /// "Mozilla Corporation" -> "Mozilla", "Valve Corp." -> "Valve"
    public static string CleanPublisher(string? p)
    {
        if (string.IsNullOrWhiteSpace(p)) return "";
        // Remove endings like ", Inc." and "Software" until none are left: "Testy Software, Inc." -> "Testy"
        string s = p.Trim(), before;
        do
        {
            before = s;
            s = Regex.Replace(s, @"[,.]?\s*\b(Inc|Ltd|LLC|GmbH|Corporation|Corp|Co|Limited|S\.?A|AG|B\.?V|Pty|Software|Technologies)\.?$", "", RegexOptions.IgnoreCase)
                     .Trim().TrimEnd(',', '.').Trim();
        } while (s != before && s.Length > 0);
        return s.Length > 0 ? s : p.Trim();
    }

    public static string Normalize(string s) => new(s.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    /// The program's install folder: from Windows' list, or worked out from its icon or uninstaller.
    public static (string? Folder, Confidence Conf) InstallFolder(InstalledApp app)
    {
        if (Paths.Clean(app.InstallLocation) is string loc && Directory.Exists(loc) && IsProgramFolder(loc)) return (loc, Confidence.Sure);
        foreach (var raw in new[] { app.DisplayIcon, ExePath(app.UninstallString) })
        {
            var exe = Paths.Clean(raw?.Split(',')[0]);
            if (exe is null || !File.Exists(exe)) continue;
            var dir = Path.GetDirectoryName(exe);
            if (dir is not null && IsProgramFolder(dir) && NameMatches(Path.GetFileName(dir), app) is not null) return (dir, Confidence.Likely);
        }
        return (null, Confidence.Possible);
    }

    /// The .exe at the start of a command line, quoted or not (but not msiexec / rundll32).
    public static string? ExePath(string? cmd)
    {
        if (string.IsNullOrWhiteSpace(cmd)) return null;
        cmd = cmd.Trim();
        string exe = cmd.StartsWith('"') ? cmd[1..Math.Max(1, cmd.IndexOf('"', 1))]
                   : (cmd.IndexOf(".exe", StringComparison.OrdinalIgnoreCase) is int i and >= 0 ? cmd[..(i + 4)] : cmd.Split(' ')[0]);
        var f = Path.GetFileName(exe).ToLowerInvariant();
        return f is "msiexec.exe" or "rundll32.exe" or "cmd.exe" ? null : exe;
    }

    /// A folder at least one level inside a program root (never a root itself, never Windows).
    static bool IsProgramFolder(string dir) =>
        Paths.ProgramRoots().Any(r => Paths.IsInside(dir, r.Root)) && !Paths.IsInside(dir, Paths.Windows);

    /// How well a folder or key name matches the program.
    public static Confidence? NameMatches(string folderName, InstalledApp app)
    {
        var names = new[] { app.Name, CleanName(app.Name) }.Where(n => n.Length >= 3 && !Generic.Contains(n)).Distinct().ToList();
        if (names.Count == 0) return null;
        if (names.Any(n => folderName.Equals(n, StringComparison.OrdinalIgnoreCase))) return Confidence.Likely;
        var nf = Normalize(Regex.Replace(folderName, @"[\s._-]*v?\d+(\.\d+)*$", ""));
        return names.Any(n => Normalize(n) == nf && nf.Length >= 4) ? Confidence.Possible : null;
    }

    public static List<Leftover> Scan(InstalledApp app, bool afterUninstall = false)
    {
        var found = new Dictionary<string, Leftover>(StringComparer.OrdinalIgnoreCase);
        void Add(Leftover l)
        {
            if (found.TryGetValue(l.Id, out var old)) { if (l.Confidence > old.Confidence) old.Confidence = l.Confidence; return; }
            found[l.Id] = l;
        }
        var publisher = CleanPublisher(app.Publisher);
        var usePublisher = publisher.Length >= 3 && !Generic.Contains(publisher);
        var (installDir, installConf) = InstallFolder(app);

        // 1. The install folder
        if (installDir is not null)
            Add(new Leftover { Kind = ItemKind.Folder, FilePath = installDir, Confidence = installConf, NeedsAdmin = NeedsAdmin(installDir) });

        // 2. Folders named after the program, in AppData, ProgramData, Program Files...
        //    and inside the maker's folder (e.g. %AppData%\Mozilla\Firefox).
        foreach (var (root, admin) in Paths.ProgramRoots())
        {
            foreach (var dir in SafeDirs(root))
            {
                var n = Path.GetFileName(dir);
                if (n.Equals("Microsoft", StringComparison.OrdinalIgnoreCase) || n.Equals("Programs", StringComparison.OrdinalIgnoreCase)) continue;
                if (NameMatches(n, app) is Confidence c) { Add(new Leftover { Kind = ItemKind.Folder, FilePath = dir, Confidence = c, NeedsAdmin = admin }); continue; }
                if (usePublisher && n.Equals(publisher, StringComparison.OrdinalIgnoreCase))
                {
                    var kids = SafeDirs(dir).ToList();
                    foreach (var kid in kids)
                        if (NameMatches(Path.GetFileName(kid), app) is Confidence kc)
                            Add(new Leftover { Kind = ItemKind.Folder, FilePath = kid, Confidence = kc, NeedsAdmin = admin });
                }
            }
        }

        // 3. Start menu and desktop shortcuts that open something in the install folder
        if (installDir is not null)
        {
            foreach (var (menu, admin) in new[] { (Paths.UserStartMenu, false), (Paths.CommonStartMenu, true) })
            {
                foreach (var lnk in SafeFiles(menu, "*.lnk", depth: 2))
                    if (Shell.ShortcutTarget(lnk) is string t && Paths.IsInside(t, installDir))
                        Add(new Leftover { Kind = ItemKind.Shortcut, FilePath = lnk, Confidence = Confidence.Sure, NeedsAdmin = admin });
                foreach (var dir in SafeDirs(menu))
                    if (NameMatches(Path.GetFileName(dir), app) is Confidence c)
                        Add(new Leftover { Kind = ItemKind.Folder, FilePath = dir, Confidence = c, NeedsAdmin = admin });
            }
            foreach (var (desk, admin) in new[] { (Paths.UserDesktop, false), (Paths.PublicDesktop, true) })
                foreach (var lnk in SafeFiles(desk, "*.lnk", depth: 1))
                    if (Shell.ShortcutTarget(lnk) is string t && Paths.IsInside(t, installDir))
                        Add(new Leftover { Kind = ItemKind.Shortcut, FilePath = lnk, Confidence = Confidence.Sure, NeedsAdmin = admin });
        }

        // 4. Registry: settings keys named after the program (and inside the maker's key)
        foreach (var (hive, view) in new[] { (RegistryHive.CurrentUser, RegistryView.Default),
                                             (RegistryHive.LocalMachine, RegistryView.Registry64),
                                             (RegistryHive.LocalMachine, RegistryView.Registry32) })
        {
            bool admin = hive == RegistryHive.LocalMachine;
            using var software = new RegPath(hive, view, "SOFTWARE").Open();
            if (software is null) continue;
            foreach (var n in software.GetSubKeyNames())
            {
                if (Safety.IsReservedKey(n)) continue;
                if (NameMatches(n, app) is Confidence c)
                    Add(new Leftover { Kind = ItemKind.RegistryKey, Reg = new RegPath(hive, view, "SOFTWARE\\" + n), Confidence = c, NeedsAdmin = admin });
                else if (usePublisher && n.Equals(publisher, StringComparison.OrdinalIgnoreCase))
                {
                    using var maker = software.OpenSubKey(n);
                    foreach (var kid in maker?.GetSubKeyNames() ?? Array.Empty<string>())
                        if (NameMatches(kid, app) is Confidence kc)
                            Add(new Leftover { Kind = ItemKind.RegistryKey, Reg = new RegPath(hive, view, $"SOFTWARE\\{n}\\{kid}"), Confidence = kc, NeedsAdmin = admin });
                }
            }

            // Start-up entries that launch something from the install folder
            if (installDir is not null)
            {
                var run = new RegPath(hive, view, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run");
                using var rk = run.Open();
                foreach (var v in rk?.GetValueNames() ?? Array.Empty<string>())
                    if (rk!.GetValue(v) is string cmd && cmd.Contains(installDir, StringComparison.OrdinalIgnoreCase))
                        Add(new Leftover { Kind = ItemKind.RegistryValue, Reg = run with { Value = v }, Confidence = Confidence.Sure, NeedsAdmin = admin });
            }
        }

        // 5. After the program's own uninstaller ran: its entry in Windows' list, if it was left behind
        if (afterUninstall && app.UninstallKey.Exists())
            Add(new Leftover { Kind = ItemKind.RegistryKey, Reg = app.UninstallKey, Confidence = Confidence.Sure,
                               NeedsAdmin = app.UninstallKey.Hive == RegistryHive.LocalMachine });

        // Never offer anything that fails the safety rules, and nothing inside something already listed
        var items = found.Values.Where(Safety.IsSafe).ToList();
        items = items.Where(i => i.FilePath is null || !items.Any(o => o.FilePath is not null && o != i && Paths.IsInside(i.FilePath, o.FilePath))).ToList();
        return items.OrderByDescending(i => i.Confidence).ThenBy(i => i.IsRegistry).ThenBy(i => i.Id).ToList();
    }

    public static bool NeedsAdmin(string path) =>
        new[] { Paths.ProgramFiles, Paths.ProgramFilesX86, Paths.ProgramData, Paths.CommonStartMenu, Paths.PublicDesktop }
            .Any(r => Paths.IsInside(path, r));

    /// Size on disk of a folder or file (registry items count as 0).
    public static long Size(Leftover l)
    {
        if (l.FilePath is null) return 0;
        try
        {
            if (File.Exists(l.FilePath)) return new FileInfo(l.FilePath).Length;
            var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
            return new DirectoryInfo(l.FilePath).EnumerateFiles("*", opts).Sum(f => f.Length);
        }
        catch { return 0; }
    }

    static IEnumerable<string> SafeDirs(string root)
    {
        try { return Directory.Exists(root) ? Directory.GetDirectories(root) : Array.Empty<string>(); }
        catch { return Array.Empty<string>(); }
    }

    static IEnumerable<string> SafeFiles(string root, string pattern, int depth)
    {
        try
        {
            if (!Directory.Exists(root)) return Array.Empty<string>();
            var opts = new EnumerationOptions { RecurseSubdirectories = depth > 1, MaxRecursionDepth = depth - 1, IgnoreInaccessible = true };
            return Directory.GetFiles(root, pattern, opts);
        }
        catch { return Array.Empty<string>(); }
    }
}
