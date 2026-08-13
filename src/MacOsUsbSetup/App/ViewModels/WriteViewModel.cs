using System.Collections.ObjectModel;
using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.Setup;

namespace MacOsUsbSetup.App.ViewModels;

/// <summary>Step 4: prepare the disk, write the EFI and download macOS, all with progress.</summary>
public sealed class WriteViewModel : ViewModelBase
{
    private readonly SetupServices _services;
    private readonly InstallPlan _plan;
    private readonly HardwareInventory _hardware;
    private readonly CancellationTokenSource _cancellation = new();

    private double _fraction;
    private string _stage = "Start";
    private string _detail = string.Empty;
    private bool _isRunning = true;

    public WriteViewModel(SetupServices services, InstallPlan plan, HardwareInventory hardware)
    {
        _services = services;
        _plan = plan;
        _hardware = hardware;
        CancelCommand = new RelayCommand(_ => _cancellation.Cancel(), _ => IsRunning);
    }

    public string Headline => "USB wird erstellt";
    public string Target => $"macOS {_plan.Release.Name} ({_plan.Release.RecoveryVersion})  →  {_plan.Target.Model}";
    public ObservableCollection<string> Log { get; } = new();
    public RelayCommand CancelCommand { get; }

    public double Fraction
    {
        get => _fraction;
        private set => Set(ref _fraction, value);
    }

    public string Stage
    {
        get => _stage;
        private set => Set(ref _stage, value);
    }

    public string Detail
    {
        get => _detail;
        private set => Set(ref _detail, value);
    }

    public bool IsRunning
    {
        get => _isRunning;
        private set
        {
            if (Set(ref _isRunning, value)) CancelCommand.RaiseCanExecuteChanged();
        }
    }

    public event Action? Completed;
    public event Action<SetupException>? Failed;

    public async Task RunAsync()
    {
        using var mirror = new LogMirror(Log);
        var progress = new Progress<ProgressReport>(report =>
        {
            Fraction = report.Fraction;
            Stage = StageText(report.Stage);
            Detail = report.Message;
        });

        try
        {
            await _services.CreateBuildJob().RunAsync(_plan, _hardware, progress, _cancellation.Token);
            IsRunning = false;
            Completed?.Invoke();
        }
        catch (OperationCanceledException)
        {
            IsRunning = false;
            Failed?.Invoke(new SetupException(SetupStage.UsbPreparation,
                "Vorgang abgebrochen – der USB-Datenträger ist unvollständig und nicht bootfähig.",
                "Setup erneut ausführen, um den Stick vollständig zu beschreiben."));
        }
        catch (SetupException ex)
        {
            IsRunning = false;
            Failed?.Invoke(ex);
        }
        catch (Exception ex)
        {
            IsRunning = false;
            Failed?.Invoke(new SetupException(SetupStage.RecoveryDownload,
                "Unerwarteter Fehler beim Erstellen des USB-Datenträgers.", "Protokoll ansehen.", ex));
        }
    }

    private static string StageText(SetupStage stage) => stage switch
    {
        SetupStage.UsbPreparation => "USB vorbereiten",
        SetupStage.EfiInstallation => "EFI schreiben",
        SetupStage.RecoveryLookup => "Recovery-Quelle abfragen",
        SetupStage.RecoveryDownload => "macOS herunterladen",
        SetupStage.Verification => "Prüfen",
        _ => stage.ToString(),
    };
}
