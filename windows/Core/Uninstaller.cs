// Uninstaller.cs - runs the program's own uninstaller first (the proper way on Windows),
// then Crumbs cleans up what it left behind.
// Part of Crumbs. MIT License.

using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Crumbs;

public static class Uninstaller
{
    /// Turns the program's uninstall command into something we can start.
    public static (string Exe, string Args)? Command(InstalledApp app)
    {
        var cmd = app.UninstallString?.Trim();
        if (string.IsNullOrEmpty(cmd)) return null;
        // Windows Installer programs: always "uninstall" (/X), never "repair" (/I)
        var msi = Regex.Match(cmd, @"msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F-]+\})", RegexOptions.IgnoreCase);
        if (msi.Success) return ("msiexec.exe", "/X" + msi.Groups[2].Value);
        if (cmd.StartsWith('"'))
        {
            var end = cmd.IndexOf('"', 1);
            if (end > 1) return (cmd[1..end], cmd[(end + 1)..].Trim());
        }
        var i = cmd.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        return i > 0 ? (cmd[..(i + 4)], cmd[(i + 4)..].Trim()) : (cmd, "");
    }

    /// Starts the uninstaller and waits until it's done (some uninstallers hand over to another
    /// process and quit early, so we also wait for the program to disappear from Windows' list).
    public static async Task<bool> RunAsync(InstalledApp app, TimeSpan? timeout = null)
    {
        if (Command(app) is not (string exe, string args)) return false;
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = true });
            if (p is null) return false;
            await p.WaitForExitAsync();
        }
        catch { return false; }   // e.g. you said No to the Windows permission question
        var until = DateTime.Now + (timeout ?? TimeSpan.FromMinutes(5));
        while (app.UninstallKey.Exists() && DateTime.Now < until) await Task.Delay(1000);
        return !app.UninstallKey.Exists();
    }
}
