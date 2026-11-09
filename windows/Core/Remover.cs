// Remover.cs - removes leftovers safely, and puts them back (Undo).
// Files and folders go to the Recycle Bin. Registry entries are saved to a backup file first.
// Part of Crumbs. MIT License.

using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;

namespace Crumbs;

public sealed record Removed(string Kind, string? FilePath, string? Hive, string? View, string? SubKey, string? Value,
                             string? BackupFile, string? ValueKind, string? ValueData);

public sealed record RemoveResult(int Removed, int Failed, int Skipped);

public static class Remover
{
    static string UndoFile => Path.Combine(Paths.CrumbsHome, "undo.json");
    static string BackupDir => Path.Combine(Paths.CrumbsHome, "Backups");

    public static RemoveResult Remove(IEnumerable<Leftover> items)
    {
        var list = items.ToList();
        // Nothing inside something else that's going anyway
        list = list.Where(i => i.FilePath is null || !list.Any(o => o.FilePath is not null && o != i && Paths.IsInside(i.FilePath, o.FilePath))).ToList();
        var undo = new List<Removed>();
        int ok = 0, failed = 0, skipped = 0;
        Directory.CreateDirectory(BackupDir);
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");

        foreach (var (item, n) in list.Select((x, n) => (x, n)))
        {
            if (!Safety.IsSafe(item)) { skipped++; continue; }    // checked again right before acting
            try
            {
                if (item.FilePath is not null)
                {
                    if (Shell.Recycle(item.FilePath)) { ok++; undo.Add(new Removed("file", item.FilePath, null, null, null, null, null, null, null)); }
                    else failed++;
                    continue;
                }
                var r = item.Reg!;
                using var baseKey = RegistryKey.OpenBaseKey(r.Hive, r.View);
                if (r.Value is null)
                {
                    // Save the whole key to a .reg file first, then remove it
                    var backup = Path.Combine(BackupDir, $"{stamp}-{n}.reg");
                    var view = r.View == RegistryView.Registry32 ? "/reg:32" : "/reg:64";
                    if (Run("reg.exe", $"export \"{r.HiveName}\\{r.SubKey}\" \"{backup}\" /y {view}") != 0) { failed++; continue; }
                    baseKey.DeleteSubKeyTree(r.SubKey, throwOnMissingSubKey: false);
                    ok++; undo.Add(new Removed("key", null, r.Hive.ToString(), r.View.ToString(), r.SubKey, null, backup, null, null));
                }
                else
                {
                    using var k = baseKey.OpenSubKey(r.SubKey, writable: true);
                    if (k is null) { failed++; continue; }
                    var data = k.GetValue(r.Value, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    var kind = k.GetValueKind(r.Value);
                    k.DeleteValue(r.Value, throwOnMissingValue: false);
                    ok++; undo.Add(new Removed("value", null, r.Hive.ToString(), r.View.ToString(), r.SubKey, r.Value, null,
                                               kind.ToString(), JsonSerializer.Serialize(data)));
                }
            }
            catch { failed++; }
        }
        Directory.CreateDirectory(Paths.CrumbsHome);
        File.WriteAllText(UndoFile, JsonSerializer.Serialize(undo));
        return new RemoveResult(ok, failed, skipped);
    }

    public static bool CanUndo => File.Exists(UndoFile) && (JsonSerializer.Deserialize<List<Removed>>(File.ReadAllText(UndoFile))?.Count ?? 0) > 0;

    /// Puts back what the last removal took. Returns (put back, couldn't).
    public static (int Ok, int Failed) Undo()
    {
        if (!File.Exists(UndoFile)) return (0, 0);
        var list = JsonSerializer.Deserialize<List<Removed>>(File.ReadAllText(UndoFile)) ?? new();
        int ok = 0, failed = 0;
        foreach (var r in list)
        {
            try
            {
                switch (r.Kind)
                {
                    case "file":
                        if (Shell.RestoreFromRecycleBin(r.FilePath!)) ok++; else failed++;
                        break;
                    case "key":
                        var view = r.View == nameof(RegistryView.Registry32) ? "/reg:32" : "/reg:64";
                        if (Run("reg.exe", $"import \"{r.BackupFile}\" {view}") == 0) ok++; else failed++;
                        break;
                    case "value":
                        using (var baseKey = RegistryKey.OpenBaseKey(Enum.Parse<RegistryHive>(r.Hive!), Enum.Parse<RegistryView>(r.View!)))
                        using (var k = baseKey.CreateSubKey(r.SubKey!, writable: true))
                        {
                            var kind = Enum.Parse<RegistryValueKind>(r.ValueKind!);
                            var json = JsonSerializer.Deserialize<JsonElement>(r.ValueData!);
                            object value = kind switch
                            {
                                RegistryValueKind.DWord => json.GetInt32(),
                                RegistryValueKind.QWord => json.GetInt64(),
                                RegistryValueKind.MultiString => json.EnumerateArray().Select(e => e.GetString() ?? "").ToArray(),
                                RegistryValueKind.Binary => json.GetBytesFromBase64(),
                                _ => json.GetString() ?? "",
                            };
                            k.SetValue(r.Value!, value, kind);
                        }
                        ok++;
                        break;
                }
            }
            catch { failed++; }
        }
        File.Delete(UndoFile);
        return (ok, failed);
    }

    static int Run(string exe, string args)
    {
        var p = Process.Start(new ProcessStartInfo(exe, args) { CreateNoWindow = true, UseShellExecute = false,
                                                                RedirectStandardOutput = true, RedirectStandardError = true })!;
        p.WaitForExit(30_000);
        return p.HasExited ? p.ExitCode : -1;
    }
}
