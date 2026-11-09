// Items.cs - what the window shows for each program and each leftover. Also program icons and settings.
// Part of Crumbs. MIT License.

using System.ComponentModel;
using System.IO;
using Path = System.IO.Path;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Crumbs;

public sealed class AppItem
{
    public required InstalledApp App { get; init; }
    public string Name => App.Name;
    public string Publisher => App.Publisher ?? "";
    public ImageSource? Icon { get; set; }
    public Visibility LockVisibility => App.IsProtected ? Visibility.Visible : Visibility.Collapsed;
}

public sealed class LeftoverItem : INotifyPropertyChanged
{
    public required Leftover L { get; init; }
    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed(string p) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(p));

    bool _checked;
    public bool IsChecked { get => _checked; set { _checked = value; Changed(nameof(IsChecked)); CheckedChanged?.Invoke(); } }
    public Action? CheckedChanged { get; set; }

    public string Title => L.IsRegistry ? (L.Kind == ItemKind.RegistryValue ? $"Starts with Windows: {L.Name}" : $"Settings in the registry: {L.Name}")
                                        : L.Name;
    public string Where => L.Where;
    public string Label => L.Confidence.ToString();
    public string LabelTip => L.Confidence switch
    {
        Confidence.Sure => "Definitely this program's (its install folder, its shortcut, or its own entry).",
        Confidence.Likely => "Has exactly this program's name.",
        _ => "Only looks similar. Check before removing.",
    };
    public Brush LabelBrush => (Brush)Application.Current.Resources[L.Confidence + "Brush"];
    public Brush LabelBackground => new SolidColorBrush(Color.FromArgb(0x26, ((SolidColorBrush)LabelBrush).Color.R,
                                                                      ((SolidColorBrush)LabelBrush).Color.G, ((SolidColorBrush)LabelBrush).Color.B));
    public Visibility DataVisibility => L.IsUserData ? Visibility.Visible : Visibility.Collapsed;
    public Visibility AdminVisibility => L.NeedsAdmin ? Visibility.Visible : Visibility.Collapsed;

    public long Size { get => L.Size; set { L.Size = value; Changed(nameof(SizeText)); } }
    public string SizeText => L.IsRegistry ? "" : Pretty(L.Size);

    public static string Pretty(long bytes)
    {
        if (bytes < 0) return "…";
        string[] u = { "bytes", "KB", "MB", "GB", "TB" };
        double v = bytes; int i = 0;
        while (v >= 1000 && i < u.Length - 1) { v /= 1000; i++; }
        return i == 0 ? $"{bytes} bytes" : $"{v:0.#} {u[i]}";
    }
}

/// Program icons, from the icon Windows shows for the program.
public static class Icons
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO { public IntPtr hIcon; public int iIcon; public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string path, uint attr, ref SHFILEINFO info, uint size, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint ExtractIconEx(string file, int index, IntPtr[]? large, IntPtr[]? small, uint n);
    const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0, SHGFI_USEFILEATTRIBUTES = 0x10;

    public static ImageSource? For(InstalledApp app)
    {
        try
        {
            var raw = app.DisplayIcon ?? Scanner.ExePath(app.UninstallString);
            if (raw is not null)
            {
                var parts = raw.Split(',');
                var file = Paths.Clean(parts[0]);
                int index = parts.Length > 1 && int.TryParse(parts[1].Trim(), out var n) ? n : 0;
                if (file is not null && File.Exists(file) && !file.EndsWith(".ico", StringComparison.OrdinalIgnoreCase))
                {
                    var large = new IntPtr[1];
                    if (ExtractIconEx(file, index, large, null, 1) > 0 && large[0] != IntPtr.Zero) return FromHandle(large[0]);
                }
                if (file is not null && File.Exists(file))
                    return BitmapFrame.Create(new Uri(file), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            }
            var info = new SHFILEINFO();
            SHGetFileInfo(".exe", 0x80, ref info, (uint)Marshal.SizeOf(info), SHGFI_ICON | SHGFI_LARGEICON | SHGFI_USEFILEATTRIBUTES);
            return info.hIcon != IntPtr.Zero ? FromHandle(info.hIcon) : null;
        }
        catch { return null; }
    }

    static ImageSource FromHandle(IntPtr h)
    {
        try
        {
            var src = Imaging.CreateBitmapSourceFromHIcon(h, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        finally { DestroyIcon(h); }
    }
}

/// Crumbs' own small settings file.
public sealed class Settings
{
    public DateTime LastUpdateCheck { get; set; }
    public bool AutoUpdateCheck { get; set; } = true;

    static string File_ => Path.Combine(Paths.CrumbsHome, "settings.json");
    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(File_)) ?? new(); } catch { return new(); }
    }
    public void Save()
    {
        try { Directory.CreateDirectory(Paths.CrumbsHome); File.WriteAllText(File_, JsonSerializer.Serialize(this)); } catch { }
    }
}
