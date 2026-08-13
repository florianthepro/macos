using System.Windows;
using System.Windows.Threading;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.App;

public partial class App : Application
{
    public App() => DispatcherUnhandledException += OnUnhandledException;

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Error($"Unbehandelter Fehler: {e.Exception}");
        MessageBox.Show(
            $"Ein unerwarteter Fehler ist aufgetreten.\n\n{e.Exception.Message}\n\nProtokoll: {Log.FilePath}",
            "macOS USB Setup", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
