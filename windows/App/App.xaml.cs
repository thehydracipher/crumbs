// App.xaml.cs - starts Crumbs for Windows with the Windows 11 look (Fluent, light or dark like your PC).
// Part of Crumbs. MIT License.

using System.Windows;

namespace Crumbs;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
#if NET9_0_OR_GREATER
        ThemeMode = ThemeMode.System;     // Windows 11 Fluent design, follows light/dark mode
#endif
        base.OnStartup(e);
    }
}
