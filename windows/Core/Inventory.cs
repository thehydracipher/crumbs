// Inventory.cs - the programs installed on this PC, read from the same list "Apps & features" uses.
// Part of Crumbs. MIT License.

using Microsoft.Win32;

namespace Crumbs;

public static class Inventory
{
    public const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";

    /// Where to read from: all users (64-bit and 32-bit lists) and just you. Tests can replace this.
    public static List<(RegistryHive Hive, RegistryView View)> Sources { get; set; } = new()
    {
        (RegistryHive.LocalMachine, RegistryView.Registry64),
        (RegistryHive.LocalMachine, RegistryView.Registry32),
        (RegistryHive.CurrentUser, RegistryView.Default),
    };

    public static List<InstalledApp> Load()
    {
        var apps = new List<InstalledApp>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (hive, view) in Sources)
        {
            using var baseKey = RegistryKey.OpenBaseKey(hive, view);
            using var list = baseKey.OpenSubKey(UninstallKey);
            if (list is null) continue;
            foreach (var keyName in list.GetSubKeyNames())
            {
                using var k = list.OpenSubKey(keyName);
                if (k is null) continue;
                var app = Read(k, new RegPath(hive, view, UninstallKey + "\\" + keyName));
                if (app is null) continue;
                if (seen.Add(app.Name + "|" + app.Version)) apps.Add(app);
            }
        }
        return apps.OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    static InstalledApp? Read(RegistryKey k, RegPath path)
    {
        string? S(string n) => (k.GetValue(n) as string)?.Trim() is { Length: > 0 } v ? v : null;
        var name = S("DisplayName");
        if (name is null) return null;
        // Hidden parts of other programs, Windows updates and patches are not programs you uninstall yourself.
        if (k.GetValue("SystemComponent") is int sc && sc == 1) return null;
        if (S("ParentKeyName") is not null) return null;
        if (S("ReleaseType") is string rt && (rt.Contains("Update") || rt.Contains("Hotfix"))) return null;
        if (path.SubKey.Split('\\').Last().StartsWith("KB", StringComparison.OrdinalIgnoreCase)) return null;
        long size = k.GetValue("EstimatedSize") is int kb ? kb * 1024L : 0;
        return new InstalledApp(name, S("Publisher"), S("DisplayVersion"), S("InstallLocation"),
            S("UninstallString"), S("QuietUninstallString"), S("DisplayIcon"), size, path);
    }
}
