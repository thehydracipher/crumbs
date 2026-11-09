// MainWindow.xaml.cs - what the Crumbs for Windows window does.
// Part of Crumbs. MIT License.

using System.Collections.ObjectModel;
using System.IO;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;

namespace Crumbs;

public partial class MainWindow : Window
{
    readonly ObservableCollection<AppItem> _shown = new();
    readonly ObservableCollection<LeftoverItem> _leftovers = new();
    List<AppItem> _all = new();
    AppItem? _current;
    int _scanNumber;                 // only the newest scan may update the screen
    bool _stillInstalled;            // the program is still installed: uninstall first, clean up after
    Release? _update;
    readonly Settings _settings = Settings.Load();

    public MainWindow()
    {
        InitializeComponent();
        AppList.ItemsSource = _shown;
        LeftoverList.ItemsSource = _leftovers;
        Loaded += async (_, _) =>
        {
            await LoadApps();
            // Crumbs.exe --show "7-Zip" opens straight onto a program
            var args = Environment.GetCommandLineArgs();
            var i = Array.IndexOf(args, "--show");
            if (i >= 0 && i + 1 < args.Length && _all.FirstOrDefault(a => a.Name.StartsWith(args[i + 1], StringComparison.OrdinalIgnoreCase)) is AppItem pick)
            { AppList.SelectedItem = pick; AppList.ScrollIntoView(pick); }
            if (_settings.AutoUpdateCheck && DateTime.Now - _settings.LastUpdateCheck > TimeSpan.FromHours(24)) await CheckForUpdates(userAsked: false);
        };
    }

    // ---------- Programs ----------

    async Task LoadApps()
    {
        var apps = await Task.Run(Inventory.Load);
        _all = apps.Select(a => new AppItem { App = a }).ToList();
        ApplyFilter();
        _ = Task.Run(() =>            // icons load in the background
        {
            foreach (var item in _all)
            {
                var icon = Icons.For(item.App);
                Dispatcher.Invoke(() => { item.Icon = icon; });
            }
            Dispatcher.Invoke(() => { AppList.Items.Refresh(); if (_current is AppItem c) DetailIcon.Source = c.Icon; });
        });
    }

    void ApplyFilter()
    {
        var q = Search.Text.Trim();
        SearchHint.Visibility = q.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _shown.Clear();
        foreach (var a in _all.Where(a => q.Length == 0 || a.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                          || a.Publisher.Contains(q, StringComparison.CurrentCultureIgnoreCase)))
            _shown.Add(a);
    }

    void OnSearch(object sender, RoutedEventArgs e) => ApplyFilter();

    void OnSelectApp(object sender, RoutedEventArgs e)
    {
        if (AppList.SelectedItem is AppItem a) Show(a);
    }

    // ---------- Home ----------

    void OnHome(object sender, RoutedEventArgs e) => GoHome();

    void GoHome(string? notice = null)
    {
        _current = null; _scanNumber++;
        AppList.SelectedItem = null;
        Detail.Visibility = Visibility.Collapsed;
        Welcome.Visibility = Visibility.Visible;
        DoneNotice.Visibility = notice is null ? Visibility.Collapsed : Visibility.Visible;
        DoneText.Text = notice is null ? "" : "✓  " + notice;
    }

    void OnKeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Escape) GoHome(); }

    // ---------- One program ----------

    void Show(AppItem a, string? message = null, bool afterUninstall = false)
    {
        _current = a;
        Welcome.Visibility = Visibility.Collapsed;
        Detail.Visibility = Visibility.Visible;
        DetailIcon.Source = a.Icon;
        DetailName.Text = a.Name;
        var bits = new[] { a.App.Publisher, a.App.Version is null ? null : "version " + a.App.Version,
                           a.App.EstimatedSizeBytes > 0 ? LeftoverItem.Pretty(a.App.EstimatedSizeBytes) : null };
        DetailSub.Text = string.Join("  ·  ", bits.Where(b => !string.IsNullOrEmpty(b)));
        SetMessage(message);
        _leftovers.Clear();
        UndoButton.Visibility = Remover.CanUndo ? Visibility.Visible : Visibility.Collapsed;

        if (a.App.IsProtected)
        {
            SetMessage(a.App.IsCrumbs ? "This is Crumbs. To remove it, use Windows Settings → Apps."
                                      : "This is part of Windows or a Microsoft program. Crumbs never touches these.");
            UninstallButton.Visibility = CleanButton.Visibility = AdminButton.Visibility = Visibility.Collapsed;
            SelectionText.Text = "";
            return;
        }
        _stillInstalled = a.App.UninstallString is not null && !afterUninstall && a.App.UninstallKey.Exists();
        UninstallButton.Visibility = _stillInstalled ? Visibility.Visible : Visibility.Collapsed;
        UninstallButton.Content = $"Uninstall {a.Name}";
        if (_stillInstalled && message is null)
            SetMessage($"Step 1: click Uninstall. Windows runs {a.Name}'s own uninstaller, then Crumbs cleans up what's left. Here's what Crumbs found so far:");
        _ = Rescan(afterUninstall);
    }

    async Task Rescan(bool afterUninstall = false)
    {
        if (_current is not AppItem a) return;
        var my = ++_scanNumber;
        Scanning.Visibility = Visibility.Visible;
        _leftovers.Clear(); UpdateSelection();
        var found = await Task.Run(() => Scanner.Scan(a.App, afterUninstall));
        if (my != _scanNumber) return;                      // you picked something else meanwhile
        Scanning.Visibility = Visibility.Collapsed;
        foreach (var l in found)
            _leftovers.Add(new LeftoverItem { L = l, IsChecked = l.Confidence >= Confidence.Likely, CheckedChanged = UpdateSelection });
        UpdateSelection();
        if (found.Count == 0 && afterUninstall)
        {
            _all.Remove(a); ApplyFilter();
            GoHome($"{a.Name} is gone. Nothing left behind.");
            return;
        }
        await Task.Run(() => { foreach (var i in _leftovers.ToList()) { var s = Scanner.Size(i.L); Dispatcher.Invoke(() => { if (my == _scanNumber) i.Size = s; }); } });
        UpdateSelection();
    }

    void UpdateSelection()
    {
        var sel = _leftovers.Where(i => i.IsChecked).ToList();
        long size = sel.Where(i => i.L.Size > 0).Sum(i => i.L.Size);
        SelectionText.Text = _leftovers.Count == 0 ? "" : $"{sel.Count} selected · {LeftoverItem.Pretty(size)}";
        CleanButton.Content = sel.Count == 0 ? "Clean up" : $"Clean up {sel.Count} item{(sel.Count == 1 ? "" : "s")}";
        CleanButton.Visibility = _leftovers.Count == 0 || _stillInstalled ? Visibility.Collapsed : Visibility.Visible;
        CleanButton.IsEnabled = sel.Count > 0;
        AdminButton.Visibility = sel.Any(i => i.L.NeedsAdmin) && !Shell.IsAdmin ? Visibility.Visible : Visibility.Collapsed;
    }

    void SetMessage(string? text)
    {
        MessagePanel.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        MessageText.Text = text ?? "";
    }

    // ---------- Uninstall, clean up, undo ----------

    async void OnUninstall(object sender, RoutedEventArgs e)
    {
        if (_current is not AppItem a) return;
        if (MessageBox.Show(this, $"Uninstall {a.Name}?\n\nWindows runs {a.Name}'s own uninstaller first. Then Crumbs shows what it left behind.",
                            "Crumbs", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        SetMessage($"Uninstalling {a.Name}… Follow the steps in its uninstaller window.");
        UninstallButton.IsEnabled = false;
        var gone = await Uninstaller.RunAsync(a.App);
        UninstallButton.IsEnabled = true;
        if (gone) Show(a, $"{a.Name} is uninstalled. Here's what it left behind.", afterUninstall: true);
        else SetMessage($"{a.Name} is still installed. If its uninstaller didn't open, try again, or remove the leftovers below.");
    }

    async void OnClean(object sender, RoutedEventArgs e)
    {
        var sel = _leftovers.Where(i => i.IsChecked).Select(i => i.L).ToList();
        if (sel.Count == 0) return;
        if (sel.Any(l => l.NeedsAdmin) && !Shell.IsAdmin)
        {
            if (MessageBox.Show(this, "Some of these need administrator rights.\n\nRestart Crumbs as administrator? (Or untick the ones marked Admin.)",
                                "Crumbs", MessageBoxButton.YesNo, MessageBoxImage.Information) == MessageBoxResult.Yes) RestartAsAdmin();
            return;
        }
        var text = $"Move {sel.Count} item{(sel.Count == 1 ? "" : "s")} to the Recycle Bin?\n\nRegistry settings are backed up first. You can Undo.";
        if (sel.Any(l => l.IsUserData)) text += "\n\nSome folders may hold your own settings or files for this program.";
        if (MessageBox.Show(this, text, "Crumbs", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        var r = await Task.Run(() => Remover.Remove(sel));
        var msg = $"Removed {r.Removed} item{(r.Removed == 1 ? "" : "s")}." +
                  (r.Failed > 0 ? $" {r.Failed} couldn't be removed (maybe in use: close the program and try again)." : "") +
                  (r.Skipped > 0 ? $" Skipped {r.Skipped} for safety." : "");
        if (_current is AppItem a) Show(a, msg, afterUninstall: !a.App.UninstallKey.Exists());
    }

    async void OnUndo(object sender, RoutedEventArgs e)
    {
        var (ok, failed) = await Task.Run(Remover.Undo);
        var msg = $"Put back {ok} item{(ok == 1 ? "" : "s")}." + (failed > 0 ? $" {failed} couldn't be put back: look in the Recycle Bin." : "");
        await LoadApps();
        if (_current is AppItem a) Show(a, msg); else GoHome(msg);
    }

    void OnRestartAdmin(object sender, RoutedEventArgs e) => RestartAsAdmin();

    void RestartAsAdmin()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true, Verb = "runas" });
            Application.Current.Shutdown();
        }
        catch { /* you said No to the Windows permission question */ }
    }

    // ---------- Drag and drop (a program's shortcut or .exe) ----------

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Link : DragDropEffects.None;
        DropOverlay.Visibility = Visibility.Visible;
        e.Handled = true;
    }

    void OnDragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    void OnDrop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files || files.Length == 0) return;
        var path = files[0];
        if (path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) path = Shell.ShortcutTarget(path) ?? path;
        var match = _all.FirstOrDefault(a => Scanner.InstallFolder(a.App).Folder is string dir && Paths.IsInside(path, dir));
        if (match is null) { GoHome("Crumbs couldn't find the program for that file."); DoneText.Text = "Crumbs couldn't find the program for that file."; return; }
        Search.Text = "";
        AppList.SelectedItem = match;
        AppList.ScrollIntoView(match);
    }

    // ---------- Updates and help ----------

    async void OnCheckUpdates(object sender, RoutedEventArgs e) => await CheckForUpdates(userAsked: true);

    async Task CheckForUpdates(bool userAsked)
    {
        try
        {
            var r = await Updater.LatestAsync();
            _settings.LastUpdateCheck = DateTime.Now; _settings.Save();
            if (r is not null && Updater.IsNewer(r.Version, Updater.CurrentVersion))
            {
                _update = r;
                UpdateText.Text = $"✨  Crumbs {r.Version} is ready.";
                UpdateBanner.Visibility = Visibility.Visible;
            }
            else if (userAsked)
                MessageBox.Show(this, $"You're up to date.\n\nCrumbs {Updater.CurrentVersion} is the newest version.", "Crumbs");
        }
        catch (Exception ex)
        {
            if (userAsked) MessageBox.Show(this, "Couldn't check for updates.\n\n" + ex.Message, "Crumbs");
        }
    }

    void OnWhatsNew(object sender, RoutedEventArgs e) { if (_update is not null) Open(_update.Page.ToString()); }
    void OnLater(object sender, RoutedEventArgs e) => UpdateBanner.Visibility = Visibility.Collapsed;

    async void OnUpdateNow(object sender, RoutedEventArgs e)
    {
        if (_update is null) return;
        UpdateNowButton.IsEnabled = false;
        UpdateText.Text = $"Downloading Crumbs {_update.Version}…";
        try
        {
            var exe = await Updater.DownloadAsync(_update);
            Updater.InstallAndRestart(exe);
            Application.Current.Shutdown();
        }
        catch (Exception ex)
        {
            UpdateNowButton.IsEnabled = true;
            UpdateText.Text = "The update didn't install.";
            if (MessageBox.Show(this, ex.Message + "\n\nOpen the download page instead?", "Crumbs", MessageBoxButton.YesNo) == MessageBoxResult.Yes)
                Open(_update.Page.ToString());
        }
    }

    void OnReportProblem(object sender, RoutedEventArgs e) => Open(Updater.ReportProblemUrl());

    static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }
}
