using System.Diagnostics;
using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Setup;

namespace MacOsUsbSetup.App.ViewModels;

/// <summary>Step 5: confirmation and the concrete boot/install steps.</summary>
public sealed class DoneViewModel : ViewModelBase
{
    public DoneViewModel(InstallPlan plan, Action restart)
    {
        Summary = $"macOS {plan.Release.Name} wurde auf {plan.Target.Model} geschrieben.";
        ShowLogCommand = new RelayCommand(_ => OpenLog());
        RestartCommand = new RelayCommand(_ => restart());
        RebootCommand = new RelayCommand(_ => Reboot());
        QuitCommand = new RelayCommand(_ => System.Windows.Application.Current.Shutdown());
    }

    public string Headline => "Fertig";
    public string Summary { get; }

    public IReadOnlyList<string> Steps { get; } = new[]
    {
        "1.  Rechner neu starten.",
        "2.  Boot-Menü öffnen (je nach Board F12, F11, F8 oder Esc).",
        "3.  Den USB-Datenträger im UEFI-Modus auswählen.",
        "4.  Im OpenCore-Menü macOS Base System starten.",
        "5.  Festplattendienstprogramm öffnen und das Ziellaufwerk als APFS löschen.",
        "6.  macOS installieren wählen und dem Assistenten folgen.",
        "7.  macOS wird dabei von Apple geladen - Internetverbindung erforderlich.",
    };

    public RelayCommand ShowLogCommand { get; }
    public RelayCommand RestartCommand { get; }
    public RelayCommand RebootCommand { get; }
    public RelayCommand QuitCommand { get; }

    private static void OpenLog()
    {
        try { Process.Start(new ProcessStartInfo(Log.FilePath) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn($"Protokoll konnte nicht geöffnet werden: {ex.Message}"); }
    }

    private static void Reboot()
    {
        try { Process.Start(new ProcessStartInfo("shutdown", "/r /t 5") { CreateNoWindow = true, UseShellExecute = false }); }
        catch (Exception ex) { Log.Warn($"Neustart konnte nicht ausgelöst werden: {ex.Message}"); }
    }
}
