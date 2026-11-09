// Updater.cs - checks GitHub for a newer Crumbs for Windows and installs it with one click.
// The only time Crumbs goes online. It sends nothing about you.
// Part of Crumbs. MIT License.

using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace Crumbs;

public sealed record Release(string Version, Uri Page, Uri Zip, string? Sha256);

public static class Updater
{
    public const string Repo = "thehydracipher/crumbs";

    public static string CurrentVersion =>
        Assembly.GetEntryAssembly()?.GetName().Version is Version v ? $"{v.Major}.{v.Minor}" + (v.Build > 0 ? $".{v.Build}" : "") : "0";

    /// The Windows download for this PC, e.g. "Windows-Crumbs-1.4-x64.zip".
    public static string AssetSuffix => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "-arm64.zip" : "-x64.zip";

    public static bool IsNewer(string a, string b)
    {
        int[] P(string s) => s.Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var (x, y) = (P(a), P(b));
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0;
            if (p != q) return p > q;
        }
        return false;
    }

    static HttpClient Http()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        h.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Crumbs-Windows", CurrentVersion));
        h.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return h;
    }

    public static async Task<Release?> LatestAsync()
    {
        using var h = Http();
        using var doc = JsonDocument.Parse(await h.GetStringAsync($"https://api.github.com/repos/{Repo}/releases/latest"));
        var root = doc.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        foreach (var a in root.GetProperty("assets").EnumerateArray())
        {
            var name = a.GetProperty("name").GetString() ?? "";
            if (!name.StartsWith("Windows-Crumbs-", StringComparison.OrdinalIgnoreCase) || !name.EndsWith(AssetSuffix, StringComparison.OrdinalIgnoreCase)) continue;
            var url = new Uri(a.GetProperty("browser_download_url").GetString()!);
            if (url.Host != "github.com" && !url.Host.EndsWith(".githubusercontent.com")) continue;
            string? sha = a.TryGetProperty("digest", out var d) && d.GetString() is string ds && ds.StartsWith("sha256:") ? ds[7..].ToLowerInvariant() : null;
            return new Release(tag.TrimStart('v'), new Uri(root.GetProperty("html_url").GetString()!), url, sha);
        }
        return null;   // this release has no Windows download yet
    }

    /// Downloads, checks the checksum, and unpacks. Returns the new Crumbs.exe.
    public static async Task<string> DownloadAsync(Release r)
    {
        using var h = Http();
        var bytes = await h.GetByteArrayAsync(r.Zip);
        if (r.Sha256 is string want && Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != want)
            throw new InvalidOperationException("The download didn't match its checksum, so it wasn't installed.");
        var dir = Path.Combine(Path.GetTempPath(), "crumbs-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var zip = Path.Combine(dir, "update.zip");
        await File.WriteAllBytesAsync(zip, bytes);
        ZipFile.ExtractToDirectory(zip, Path.Combine(dir, "new"));
        var exe = Directory.GetFiles(Path.Combine(dir, "new"), "Crumbs.exe", SearchOption.AllDirectories).FirstOrDefault()
                  ?? throw new InvalidOperationException("The download isn't a valid Crumbs.");
        return exe;
    }

    /// Swaps in the new Crumbs.exe once this one has closed, then opens it.
    public static void InstallAndRestart(string newExe)
    {
        var me = Environment.ProcessPath ?? throw new InvalidOperationException("Can't find Crumbs.exe.");
        var script = Path.Combine(Path.GetTempPath(), "crumbs-update-" + Guid.NewGuid().ToString("N") + ".cmd");
        File.WriteAllText(script,
            "@echo off\r\n" +
            $":wait\r\ntasklist /fi \"PID eq {Environment.ProcessId}\" | find \"{Environment.ProcessId}\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
            $"copy /y \"{newExe}\" \"{me}\" >nul\r\n" +
            $"start \"\" \"{me}\"\r\n" +
            "del \"%~f0\"\r\n");
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{script}\"") { CreateNoWindow = true, UseShellExecute = false });
    }

    /// A ready-made GitHub bug report with the basics filled in (nothing is sent until you submit it).
    public static string ReportProblemUrl() =>
        $"https://github.com/{Repo}/issues/new?template=bug_report.yml&version={Uri.EscapeDataString(CurrentVersion)}" +
        $"&os={Uri.EscapeDataString(RuntimeInformation.OSDescription)}&computer={Uri.EscapeDataString("Windows PC")}";
}
