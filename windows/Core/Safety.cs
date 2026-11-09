// Safety.cs - the last check before anything is removed. Each kind of item may only be in a few known places.
// Part of Crumbs. MIT License.

using Microsoft.Win32;

namespace Crumbs;

public static class Safety
{
    /// Registry keys under SOFTWARE that belong to Windows itself.
    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "Microsoft", "Classes", "Policies", "Wow6432Node", "Windows", "Clients", "RegisteredApplications",
        "WOW6432Node", "Intel", "ODBC", "Partner", "DefaultUserEnvironment", "Khronos", "Realtek", "OEM",
    };
    public static bool IsReservedKey(string name) => Reserved.Contains(name);

    /// Folders that hold your own things: never removed themselves.
    static IEnumerable<string> PersonalFolders() => new[]
    {
        Paths.UserProfile, Paths.UserDesktop, Paths.PublicDesktop, Paths.Downloads,
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        Environment.GetFolderPath(Environment.SpecialFolder.MyMusic),
        Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
    }.Where(p => !string.IsNullOrEmpty(p));

    public static bool IsSafe(Leftover l) => l.FilePath is not null ? IsSafeFile(l) : IsSafeReg(l.Reg!);

    static bool IsSafeFile(Leftover l)
    {
        string p;
        try { p = Path.GetFullPath(l.FilePath!).TrimEnd('\\'); } catch { return false; }
        if (!File.Exists(p) && !Directory.Exists(p)) return false;
        // Never Windows, never your personal folders themselves, never links that lead somewhere else
        if (Paths.IsInside(p, Paths.Windows) || p.Equals(Paths.Windows, StringComparison.OrdinalIgnoreCase)) return false;
        if (PersonalFolders().Any(f => p.Equals(f.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))) return false;
        try { if (File.GetAttributes(p).HasFlag(FileAttributes.ReparsePoint)) return false; } catch { return false; }

        // Shortcuts: only .lnk files on the desktop or in the Start menu
        if (l.Kind == ItemKind.Shortcut)
            return p.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) &&
                   (Directly(p, Paths.UserDesktop) || Directly(p, Paths.PublicDesktop)
                    || Paths.IsInside(p, Paths.UserStartMenu) || Paths.IsInside(p, Paths.CommonStartMenu));

        // Start menu folders
        if (Paths.IsInside(p, Paths.UserStartMenu) || Paths.IsInside(p, Paths.CommonStartMenu)) return true;

        // Program folders: inside a program root, never the root itself, never Microsoft's own folder
        foreach (var (root, _) in Paths.ProgramRoots())
        {
            if (!Paths.IsInside(p, root)) continue;
            var first = p[(root.TrimEnd('\\').Length + 1)..].Split('\\')[0];
            if (first.Equals("Microsoft", StringComparison.OrdinalIgnoreCase) || first.Equals("WindowsApps", StringComparison.OrdinalIgnoreCase)
                || first.Equals("Common Files", StringComparison.OrdinalIgnoreCase) || first.Equals("Package Cache", StringComparison.OrdinalIgnoreCase)
                || first.Equals("Crumbs", StringComparison.OrdinalIgnoreCase)) return false;
            // "Programs" inside LocalAppData is itself a root
            if (p.Equals(Paths.LocalPrograms, StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }
        return false;
    }

    static bool Directly(string p, string folder) =>
        !string.IsNullOrEmpty(folder) && string.Equals(Path.GetDirectoryName(p), folder.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    static bool IsSafeReg(RegPath r)
    {
        if (r.Hive != RegistryHive.CurrentUser && r.Hive != RegistryHive.LocalMachine) return false;
        var parts = r.SubKey.Split('\\');
        if (parts.Length < 2 || !parts[0].Equals("SOFTWARE", StringComparison.OrdinalIgnoreCase)) return false;
        var path = r.SubKey;
        // A program's own entry in Windows' list of programs (left behind by its uninstaller)
        if (path.StartsWith(Inventory.UninstallKey + "\\", StringComparison.OrdinalIgnoreCase) && parts.Length == 6 && r.Value is null) return true;
        // A start-up entry (one value only)
        if (path.Equals(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", StringComparison.OrdinalIgnoreCase) && r.Value is not null) return true;
        // Settings keys of programs: SOFTWARE\<Program> or SOFTWARE\<Maker>\<Program>, never Windows' own keys
        return r.Value is null && parts.Length <= 3 && !IsReservedKey(parts[1]);
    }
}
