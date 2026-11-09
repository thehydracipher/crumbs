// Models.cs - the things Crumbs for Windows works with.
// Part of Crumbs. MIT License.

using Microsoft.Win32;

namespace Crumbs;

/// How sure Crumbs is that a leftover belongs to the program.
public enum Confidence { Possible = 0, Likely = 1, Sure = 2 }

public enum ItemKind { Folder, File, Shortcut, RegistryKey, RegistryValue }

/// A place in the registry, e.g. HKEY_CURRENT_USER\Software\Maker\App (and optionally one value in it).
public sealed record RegPath(RegistryHive Hive, RegistryView View, string SubKey, string? Value = null)
{
    public string HiveName => Hive == RegistryHive.LocalMachine ? "HKEY_LOCAL_MACHINE" : "HKEY_CURRENT_USER";
    public string Short => (Hive == RegistryHive.LocalMachine ? "HKLM" : "HKCU") + "\\" + SubKey;
    public override string ToString() => Short + (Value is null ? "" : $"  ({Value})");

    public RegistryKey? Open(bool writable = false)
    {
        try { return RegistryKey.OpenBaseKey(Hive, View).OpenSubKey(SubKey, writable); }
        catch { return null; }
    }

    public bool Exists()
    {
        using var k = Open();
        if (k is null) return false;
        return Value is null || k.GetValueNames().Contains(Value, StringComparer.OrdinalIgnoreCase);
    }
}

/// A program installed on this PC (from the list Windows keeps in "Apps & features").
public sealed record InstalledApp(
    string Name, string? Publisher, string? Version, string? InstallLocation,
    string? UninstallString, string? QuietUninstallString, string? DisplayIcon,
    long EstimatedSizeBytes, RegPath UninstallKey)
{
    public string Id => UninstallKey.Short + "|" + UninstallKey.View;

    /// Windows itself and Microsoft's own programs are never touched, like Apple's apps on the Mac.
    public bool IsProtected =>
        Scanner.Normalize(Publisher ?? "").StartsWith("microsoftcorp")   // "Microsoft Corporation", "Microsoft® Corporation", "Microsoft Corp."
        || Name.StartsWith("Microsoft Visual C++", StringComparison.OrdinalIgnoreCase)
        || Name.StartsWith("Windows ", StringComparison.OrdinalIgnoreCase)
        || Name.Equals("Crumbs", StringComparison.OrdinalIgnoreCase);

    public bool IsCrumbs => Name.Equals("Crumbs", StringComparison.OrdinalIgnoreCase);
}

/// Something a program left behind.
public sealed class Leftover
{
    public required ItemKind Kind { get; init; }
    public string? FilePath { get; init; }        // for folders, files and shortcuts
    public RegPath? Reg { get; init; }            // for registry keys and values
    public required Confidence Confidence { get; set; }
    public long Size { get; set; } = -1;          // -1 until measured
    public bool NeedsAdmin { get; init; }

    public string Id => FilePath ?? Reg!.ToString();
    public string Name => FilePath is not null ? System.IO.Path.GetFileName(FilePath.TrimEnd('\\'))
                                               : (Reg!.Value ?? Reg.SubKey.Split('\\').Last());
    public string Where => FilePath is not null ? Paths.Pretty(System.IO.Path.GetDirectoryName(FilePath.TrimEnd('\\')) ?? "")
                                                : (Reg!.Value is null ? Reg.Short[..Math.Max(0, Reg.Short.LastIndexOf('\\'))] : Reg.Short);
    public bool IsRegistry => Reg is not null;

    /// Folders that usually hold your own data (settings, documents, history).
    public bool IsUserData => FilePath is not null && Kind == ItemKind.Folder &&
        (FilePath.StartsWith(Paths.AppData, StringComparison.OrdinalIgnoreCase)
         || FilePath.StartsWith(Paths.LocalAppData, StringComparison.OrdinalIgnoreCase)) &&
        !FilePath.Contains("\\Cache", StringComparison.OrdinalIgnoreCase);
}
