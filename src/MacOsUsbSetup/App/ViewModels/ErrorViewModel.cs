using System.Diagnostics;
using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.App.ViewModels;

/// <summary>Shown for any <see cref="SetupException"/>: what failed, why, and the fix.</summary>
public sealed class ErrorViewModel : ViewModelBase
{
    public ErrorViewModel(SetupException error, Action back)
    {
        StageText = StageLabel(error.Stage);
        Message = error.Message;
        Remedy = error.Remedy;
        ShowLogCommand = new RelayCommand(_ => OpenLog());
        BackCommand = new RelayCommand(_ => back());
        QuitCommand = new RelayCommand(_ => System.Windows.Application.Current.Shutdown());
    }

    public string Headline => "Vorgang fehlgeschlagen";
    public string StageText { get; }
    public string Message { get; }
    public string? Remedy { get; }
    public bool HasRemedy => !string.IsNullOrWhiteSpace(Remedy);

    public RelayCommand ShowLogCommand { get; }
    public RelayCommand BackCommand { get; }
    public RelayCommand QuitCommand { get; }

    private static string StageLabel(SetupStage stage) => stage switch
    {
        SetupStage.HardwareScan => "Hardware-Analyse",
        SetupStage.Compatibility => "Kompatibilitätsprüfung",
        SetupStage.RecoveryLookup => "Recovery-Abfrage",
        SetupStage.RecoveryDownload => "macOS-Download",
        SetupStage.UsbPreparation => "USB-Vorbereitung",
        SetupStage.EfiInstallation => "EFI-Installation",
        SetupStage.Verification => "Prüfung",
        _ => stage.ToString(),
    };

    private static void OpenLog()
    {
        try { Process.Start(new ProcessStartInfo(Log.FilePath) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn($"Protokoll konnte nicht geöffnet werden: {ex.Message}"); }
    }
}
