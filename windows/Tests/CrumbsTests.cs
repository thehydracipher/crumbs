// Tests for Crumbs for Windows. They run on a real Windows machine (GitHub Actions) with a fake program:
// fake folders in a temporary place, and fake registry entries under your user (removed afterwards).
// Part of Crumbs. MIT License.

using Microsoft.Win32;
using Xunit;

namespace Crumbs.Tests;

public sealed class FakeProgram : IDisposable
{
    public readonly string Root = Path.Combine(Path.GetTempPath(), "crumbs-test-" + Guid.NewGuid().ToString("N")[..8]);
    public readonly string Id = "CrumbsTest-" + Guid.NewGuid().ToString("N")[..8];
    public const string Name = "Testy Widget";
    public const string Maker = "Testy Software";
    public string InstallDir => Path.Combine(Paths.ProgramFiles, Name);
    public string Exe => Path.Combine(InstallDir, "testy.exe");

    public FakeProgram()
    {
        // Point every place Crumbs looks at fake folders
        string D(string n) { var p = Path.Combine(Root, n); Directory.CreateDirectory(p); return p; }
        Paths.AppData = D("AppData\\Roaming"); Paths.LocalAppData = D("AppData\\Local"); Paths.LocalLow = D("AppData\\LocalLow");
        Paths.ProgramData = D("ProgramData"); Paths.ProgramFiles = D("Program Files"); Paths.ProgramFilesX86 = D("Program Files (x86)");
        Paths.UserStartMenu = D("StartMenu\\User"); Paths.CommonStartMenu = D("StartMenu\\Common");
        Paths.UserDesktop = D("Desktop"); Paths.PublicDesktop = D("PublicDesktop"); Paths.Downloads = D("Downloads");
        Paths.UserProfile = Root;

        Directory.CreateDirectory(InstallDir); File.WriteAllText(Exe, "fake");
        Directory.CreateDirectory(Path.Combine(Paths.AppData, Name)); File.WriteAllText(Path.Combine(Paths.AppData, Name, "settings.ini"), "x");
        Directory.CreateDirectory(Path.Combine(Paths.LocalAppData, "Testy", Name));          // maker folder (publisher "Testy Software" -> "Testy")
        Directory.CreateDirectory(Path.Combine(Paths.LocalAppData, Name + " 2"));            // near name -> possible
        Directory.CreateDirectory(Path.Combine(Paths.AppData, Name + "tron"));               // look-alike -> never
        Directory.CreateDirectory(Path.Combine(Paths.AppData, "Microsoft", Name));            // inside Microsoft's folder -> never
        Shell.CreateShortcut(Path.Combine(Paths.UserStartMenu, Name + ".lnk"), Exe);
        Shell.CreateShortcut(Path.Combine(Paths.UserDesktop, Name + ".lnk"), Exe);
        File.WriteAllText(Path.Combine(Paths.UserDesktop, "My notes.txt"), "keep me");

        using (var k = Registry.CurrentUser.CreateSubKey(Inventory.UninstallKey + "\\" + Id))
        {
            k.SetValue("DisplayName", Name); k.SetValue("Publisher", Maker + ", Inc."); k.SetValue("DisplayVersion", "5.2");
            k.SetValue("InstallLocation", InstallDir); k.SetValue("UninstallString", $"\"{Exe}\" /uninstall");
        }
        using (var k = Registry.CurrentUser.CreateSubKey($"Software\\Testy\\{Name}")) k.SetValue("Theme", "dark");
        using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) k.SetValue(Id, $"\"{Exe}\" --background");
    }

    public InstalledApp App => Inventory.Load().Single(a => a.UninstallKey.SubKey.EndsWith(Id));

    public void Dispose()
    {
        Registry.CurrentUser.DeleteSubKeyTree(Inventory.UninstallKey + "\\" + Id, false);
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Testy", false);
        using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)) k?.DeleteValue(Id, false);
        try { Directory.Delete(Root, true); } catch { }
    }
}

[Collection("registry")]   // these tests share the real registry, so run them one at a time
public class CrumbsTests
{
    static Leftover? Find(List<Leftover> items, string path) => items.FirstOrDefault(i => string.Equals(i.FilePath, path, StringComparison.OrdinalIgnoreCase));

    [Fact]
    public void Names_are_cleaned()
    {
        Assert.Equal("7-Zip", Scanner.CleanName("7-Zip 23.01 (x64 edition)"));
        Assert.Equal("VLC media player", Scanner.CleanName("VLC media player 3.0.20"));
        Assert.Equal("Mozilla", Scanner.CleanPublisher("Mozilla Corporation"));
        Assert.Equal("Valve", Scanner.CleanPublisher("Valve Corp."));
    }

    [Fact]
    public void Finds_the_program_in_Windows_list()
    {
        using var f = new FakeProgram();
        var app = f.App;
        Assert.Equal("Testy Software, Inc.", app.Publisher);
        Assert.False(app.IsProtected);
    }

    [Fact]
    public void Microsoft_programs_are_protected()
    {
        var ms = new InstalledApp("Microsoft Edge", "Microsoft Corporation", "1", null, null, null, null, 0,
                                  new RegPath(RegistryHive.CurrentUser, RegistryView.Default, "x"));
        Assert.True(ms.IsProtected);
        Assert.True((ms with { Publisher = "Microsoft® Corporation" }).IsProtected);
        Assert.True((ms with { Name = "Azure Tool", Publisher = "Microsoft Corp." }).IsProtected);
        Assert.False((ms with { Name = "Testy", Publisher = "Microfun Studios" }).IsProtected);
    }

    [Fact]
    public void Finds_leftovers_with_the_right_labels()
    {
        using var f = new FakeProgram();
        var items = Scanner.Scan(f.App);
        Assert.Equal(Confidence.Sure, Find(items, f.InstallDir)?.Confidence);                                       // install folder
        Assert.Equal(Confidence.Likely, Find(items, Path.Combine(Paths.AppData, FakeProgram.Name))?.Confidence);     // exact name
        Assert.Equal(Confidence.Likely, Find(items, Path.Combine(Paths.LocalAppData, "Testy", FakeProgram.Name))?.Confidence); // maker folder
        Assert.Equal(Confidence.Possible, Find(items, Path.Combine(Paths.LocalAppData, FakeProgram.Name + " 2"))?.Confidence); // near name
        Assert.Null(Find(items, Path.Combine(Paths.AppData, FakeProgram.Name + "tron")));                           // look-alike: never
        Assert.Null(Find(items, Path.Combine(Paths.AppData, "Microsoft", FakeProgram.Name)));                        // Microsoft's folder: never
        Assert.Equal(Confidence.Sure, Find(items, Path.Combine(Paths.UserStartMenu, FakeProgram.Name + ".lnk"))?.Confidence);
        Assert.Equal(Confidence.Sure, Find(items, Path.Combine(Paths.UserDesktop, FakeProgram.Name + ".lnk"))?.Confidence);
        Assert.Null(Find(items, Path.Combine(Paths.UserDesktop, "My notes.txt")));                                 // your files: never
        Assert.Contains(items, i => i.Reg?.SubKey == $"SOFTWARE\\Testy\\{FakeProgram.Name}" && i.Confidence == Confidence.Likely);
        Assert.Contains(items, i => i.Reg?.Value == f.Id && i.Confidence == Confidence.Sure);                       // start-up entry
    }

    [Fact]
    public void Safety_rules()
    {
        using var f = new FakeProgram();
        bool Safe(string p, ItemKind k = ItemKind.Folder) => Safety.IsSafe(new Leftover { Kind = k, FilePath = p, Confidence = Confidence.Sure });
        bool SafeReg(string sub, string? v = null) => Safety.IsSafe(new Leftover { Kind = ItemKind.RegistryKey, Reg = new RegPath(RegistryHive.CurrentUser, RegistryView.Default, sub, v), Confidence = Confidence.Sure });
        Assert.False(Safe(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32")));
        Assert.False(Safe(Paths.AppData));                                  // a root itself
        Assert.False(Safe(Paths.UserDesktop));                              // your desktop itself
        Assert.False(Safe(Path.Combine(Paths.UserDesktop, "My notes.txt"), ItemKind.Shortcut));   // not a shortcut
        Assert.True(Safe(Path.Combine(Paths.AppData, FakeProgram.Name)));
        Assert.False(SafeReg(@"SOFTWARE\Microsoft\Office"));
        Assert.False(SafeReg(@"SOFTWARE\Classes\.txt"));
        Assert.False(SafeReg("SOFTWARE"));
        Assert.True(SafeReg($"SOFTWARE\\Testy\\{FakeProgram.Name}"));
        Assert.True(SafeReg(Inventory.UninstallKey + "\\" + f.Id));
        // A folder link (junction) that leads somewhere else is never removed
        var target = Path.Combine(f.Root, "elsewhere"); Directory.CreateDirectory(target);
        var junction = Path.Combine(Paths.AppData, "Sneaky");
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{junction}\" \"{target}\"") { CreateNoWindow = true, UseShellExecute = false })!.WaitForExit();
        Assert.True(Directory.Exists(junction));
        Assert.False(Safe(junction));
    }

    [Fact]
    public void Removes_and_undoes()
    {
        using var f = new FakeProgram();
        var items = Scanner.Scan(f.App).Where(i => i.Confidence >= Confidence.Likely).ToList();
        var r = Remover.Remove(items);
        Assert.Equal(0, r.Failed);
        Assert.False(Directory.Exists(Path.Combine(Paths.AppData, FakeProgram.Name)));
        Assert.Null(Registry.CurrentUser.OpenSubKey($"Software\\Testy\\{FakeProgram.Name}"));
        using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) Assert.Null(run?.GetValue(f.Id));
        Assert.True(File.Exists(Path.Combine(Paths.UserDesktop, "My notes.txt")));                     // untouched
        Assert.True(Directory.GetFiles(Path.Combine(Paths.CrumbsHome, "Backups"), "*.reg").Length > 0);  // registry backed up

        var (ok, failed) = Remover.Undo();
        Assert.True(ok > 0);
        using (var k = Registry.CurrentUser.OpenSubKey($"Software\\Testy\\{FakeProgram.Name}")) Assert.Equal("dark", k?.GetValue("Theme"));
        using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) Assert.NotNull(run?.GetValue(f.Id));
        Assert.True(Directory.Exists(Path.Combine(Paths.AppData, FakeProgram.Name)), $"folder back from the Recycle Bin (put back {ok}, failed {failed})");
    }

    [Fact]
    public void Uninstall_commands()
    {
        InstalledApp With(string cmd) => new("X", null, null, null, cmd, null, null, 0, new RegPath(RegistryHive.CurrentUser, RegistryView.Default, "x"));
        Assert.Equal(("msiexec.exe", "/X{12345678-ABCD-1234-ABCD-1234567890AB}"),
                     Uninstaller.Command(With("MsiExec.exe /I{12345678-ABCD-1234-ABCD-1234567890AB}")));
        Assert.Equal((@"C:\Program Files\App\uninst.exe", "/S"), Uninstaller.Command(With("\"C:\\Program Files\\App\\uninst.exe\" /S")));
        Assert.Equal((@"C:\Apps\uninstall.exe", "--quiet"), Uninstaller.Command(With(@"C:\Apps\uninstall.exe --quiet")));
    }

    [Fact]
    public void Versions_compare()
    {
        Assert.True(Updater.IsNewer("1.10", "1.9"));
        Assert.False(Updater.IsNewer("1.4", "1.4"));
        Assert.True(Updater.IsNewer("2", "1.9.9"));
    }
}

[CollectionDefinition("registry", DisableParallelization = true)]
public class RegistryCollection { }
