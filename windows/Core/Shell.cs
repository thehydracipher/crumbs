// Shell.cs - small bridges to Windows: shortcut targets, the Recycle Bin, and running as administrator.
// Part of Crumbs. MIT License.

using System.Runtime.InteropServices;
using System.Security.Principal;

namespace Crumbs;

public static class Shell
{
    /// Where a .lnk shortcut points.
    public static string? ShortcutTarget(string lnk)
    {
        try
        {
            var t = Type.GetTypeFromProgID("WScript.Shell");
            if (t is null) return null;
            dynamic sh = Activator.CreateInstance(t)!;
            dynamic sc = sh.CreateShortcut(lnk);
            string target = sc.TargetPath;
            return string.IsNullOrWhiteSpace(target) ? null : Paths.Clean(target);
        }
        catch { return null; }
    }

    /// Makes a shortcut (used by the tests).
    public static void CreateShortcut(string lnk, string target)
    {
        var t = Type.GetTypeFromProgID("WScript.Shell")!;
        dynamic sh = Activator.CreateInstance(t)!;
        dynamic sc = sh.CreateShortcut(lnk);
        sc.TargetPath = target;
        sc.Save();
    }

    public static bool IsAdmin
    {
        get { try { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); } catch { return false; } }
    }

    // ---- Recycle Bin ----

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd; public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string? pTo;
        public ushort fFlags; public int fAnyOperationsAborted; public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
    const uint FO_DELETE = 3;
    const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    /// Sends a file or folder to the Recycle Bin (never deletes for good).
    public static bool Recycle(string path)
    {
        var op = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE, pFrom = path + "\0\0",
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
        };
        return SHFileOperation(ref op) == 0 && op.fAnyOperationsAborted == 0 && !File.Exists(path) && !Directory.Exists(path);
    }

    /// Puts an item back from the Recycle Bin, by its original path. Best effort.
    public static bool RestoreFromRecycleBin(string originalPath)
    {
        try
        {
            var t = Type.GetTypeFromProgID("Shell.Application")!;
            dynamic shell = Activator.CreateInstance(t)!;
            dynamic bin = shell.NameSpace(10);            // the Recycle Bin
            foreach (dynamic item in bin.Items())
            {
                string where = bin.GetDetailsOf(item, 1);  // "Original location"
                string name = item.Name;
                var full = Path.Combine(where ?? "", name ?? "");
                if (!full.Equals(originalPath, StringComparison.OrdinalIgnoreCase)
                    && !(where + "\\" + Path.GetFileName(originalPath)).Equals(originalPath, StringComparison.OrdinalIgnoreCase)) continue;
                item.InvokeVerb("undelete");
                return File.Exists(originalPath) || Directory.Exists(originalPath);
            }
        }
        catch { }
        return false;
    }
}
