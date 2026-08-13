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
        DispatcherUnhandledException += OnDispatcherException;
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Report(e.ExceptionObject as Exception, "AppDomain");
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Report(e.Exception, "Task");
            e.SetObserved();
        };
    }

    // Build the window before wiring the view model, so a failure in scanning or
    // service construction still leaves a visible window plus a written crash log,
    // instead of a silent windowless process.
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var window = new MainWindow();
            window.Show();
            window.DataContext = new WizardViewModel();
        }
        catch (Exception ex)
        {
            Report(ex, "Startup");
            Shutdown(1);
        }
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Report(e.Exception, "Dispatcher");
        e.Handled = true;
    }

    private static void Report(Exception? exception, string origin)
    {
        var details = $"[{origin}] {exception}";
        var crashFile = Path.Combine(Path.GetTempPath(), "MacOsUsbSetup", $"crash-{DateTime.Now:yyyyMMdd-HHmmss}.log");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(crashFile)!);
            File.WriteAllText(crashFile, details, Encoding.UTF8);
        }
        catch { /* never fail while reporting a failure */ }

        try { Log.Error(details); } catch { /* logging is best-effort here */ }

        MessageBox.Show(
            $"Startfehler ({origin}):\n\n{exception?.Message}\n\nDetails: {crashFile}",
            "macOS USB Setup", MessageBoxButton.OK, MessageBoxImage.Error);
    }
}
