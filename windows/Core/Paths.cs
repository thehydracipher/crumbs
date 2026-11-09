// Paths.cs - the folders Crumbs looks in. Tests can point these at a fake folder.
// Part of Crumbs. MIT License.

namespace Crumbs;

public static class Paths
{
    static string Env(Environment.SpecialFolder f) => Environment.GetFolderPath(f);

    // Overridable for tests
    public static string AppData { get; set; } = Env(Environment.SpecialFolder.ApplicationData);
    public static string LocalAppData { get; set; } = Env(Environment.SpecialFolder.LocalApplicationData);
    public static string LocalLow { get; set; } = Path.Combine(Path.GetDirectoryName(Env(Environment.SpecialFolder.LocalApplicationData)) ?? "", "LocalLow");
    public static string ProgramData { get; set; } = Env(Environment.SpecialFolder.CommonApplicationData);
    public static string ProgramFiles { get; set; } = Env(Environment.SpecialFolder.ProgramFiles);
    public static string ProgramFilesX86 { get; set; } = Env(Environment.SpecialFolder.ProgramFilesX86);
    public static string UserStartMenu { get; set; } = Env(Environment.SpecialFolder.Programs);
    public static string CommonStartMenu { get; set; } = Env(Environment.SpecialFolder.CommonPrograms);
    public static string UserDesktop { get; set; } = Env(Environment.SpecialFolder.DesktopDirectory);
    public static string PublicDesktop { get; set; } = Env(Environment.SpecialFolder.CommonDesktopDirectory);
    public static string Downloads { get; set; } = Path.Combine(Env(Environment.SpecialFolder.UserProfile), "Downloads");
    public static string Windows { get; set; } = Env(Environment.SpecialFolder.Windows);
    public static string UserProfile { get; set; } = Env(Environment.SpecialFolder.UserProfile);

    public static string LocalPrograms => Path.Combine(LocalAppData, "Programs");

    /// Where Crumbs keeps its own things (Undo list, registry backups).
    public static string CrumbsHome => Path.Combine(LocalAppData, "Crumbs");

    /// Folders where programs keep their files, and whether removing there needs administrator rights.
    public static IEnumerable<(string Root, bool Admin)> ProgramRoots()
    {
        yield return (AppData, false);
        yield return (LocalAppData, false);
        yield return (LocalPrograms, false);
        yield return (LocalLow, false);
        yield return (ProgramData, true);
        yield return (ProgramFiles, true);
        if (!string.Equals(ProgramFilesX86, ProgramFiles, StringComparison.OrdinalIgnoreCase)) yield return (ProgramFilesX86, true);
    }

    public static string Pretty(string p)
    {
        foreach (var (root, name) in new[] { (LocalAppData, "%LocalAppData%"), (AppData, "%AppData%"), (ProgramData, "%ProgramData%"), (UserProfile, "~") })
            if (!string.IsNullOrEmpty(root) && p.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return name + p[root.Length..];
        return p;
    }

    /// "C:\Program Files\App\" -> "C:\Program Files\App", with environment variables and quotes removed.
    public static string? Clean(string? p)
    {
        if (string.IsNullOrWhiteSpace(p)) return null;
        p = Environment.ExpandEnvironmentVariables(p.Trim().Trim('"'));
        try { return Path.GetFullPath(p).TrimEnd('\\'); } catch { return null; }
    }

    public static bool IsInside(string path, string folder) =>
        !string.IsNullOrEmpty(folder) && path.StartsWith(folder.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
}
