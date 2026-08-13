using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.App;

public partial class App : Application
{
    public App()
    {
        DispatcherUnhandledException += (_, e) => { Report(e.Exception, "Dispatcher"); e.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Report(e.ExceptionObject as Exception, "AppDomain");
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Report(e.Exception, "Task");
            e.SetObserved();
        };
    }

    // Build and show the window first, then start the scan from Loaded, so the window
    // is fully realized before any work runs and every failure has a place to surface.
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var viewModel = new WizardViewModel();
            var window = new MainWindow { DataContext = viewModel };
            window.Loaded += (_, __) =>
            {
                try { viewModel.Start(); }
                catch (Exception ex) { Report(ex, "Start"); }
            };
            window.Show();
        }
        catch (Exception ex)
        {
            Report(ex, "Startup");
            Shutdown(1);
        }
    }

    /// <summary>Writes a full crash log and shows a dialog on the UI thread if one is alive.</summary>
    internal static void Report(Exception? exception, string origin)
    {
        var details = $"[{origin}] {exception}";
        var crashFile = Path.Combine(Path.GetTempPath(), "MacOsUsbSetup", $"crash-{DateTime.Now:yyyyMMdd-HHmmss-fff}.log");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(crashFile)!);
            File.WriteAllText(crashFile, details, Encoding.UTF8);
        }
        catch { /* never fail while reporting a failure */ }

        try { Log.Error(details); } catch { /* logging is best-effort here */ }

        void Show() => MessageBox.Show(
            $"Startfehler ({origin}):\n\n{exception?.Message}\n\nDetails: {crashFile}",
            "macOS USB Setup", MessageBoxButton.OK, MessageBoxImage.Error);

        // Marshal to the UI thread; a modal dialog on the finalizer/background thread may not
        // show and could stall finalization. If no dispatcher is alive, the crash log stands alone.
        var dispatcher = Current?.Dispatcher;
        if (dispatcher is null || dispatcher.HasShutdownStarted)
            return;
        if (dispatcher.CheckAccess())
            Show();
        else
            dispatcher.BeginInvoke((Action)Show);
    }
}
