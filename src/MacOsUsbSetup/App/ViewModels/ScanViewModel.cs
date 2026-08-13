using System.Collections.ObjectModel;
using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Hardware;

namespace MacOsUsbSetup.App.ViewModels;

/// <summary>Step 1: scans hardware behind a progress bar, then hands off the result.</summary>
public sealed class ScanViewModel : ViewModelBase
{
    private const int MinimumVisibleMilliseconds = 800;

    private readonly SetupServices _services;
    private bool _isScanning = true;

    public ScanViewModel(SetupServices services) => _services = services;

    public string Headline => "Hardware wird analysiert";
    public string Caption => "Prozessor, Grafik und Firmware werden gelesen.";
    public ObservableCollection<string> Log { get; } = new();

    public bool IsScanning
    {
        get => _isScanning;
        private set => Set(ref _isScanning, value);
    }

    public event Action<HardwareInventory, IReadOnlyList<CompatibilityResult>>? Completed;
    public event Action<SetupException>? Failed;

    public async Task RunAsync()
    {
        using var mirror = new LogMirror(Log);
        try
        {
            var work = Task.Run(() =>
            {
                var inventory = _services.HardwareScanner.Scan();
                var results = _services.Compatibility.Evaluate(inventory);
                return (inventory, results);
            });

            await Task.Delay(MinimumVisibleMilliseconds);
            var (inventory, results) = await work;

            IsScanning = false;
            Completed?.Invoke(inventory, results);
        }
        catch (SetupException ex)
        {
            IsScanning = false;
            Failed?.Invoke(ex);
        }
        catch (Exception ex)
        {
            IsScanning = false;
            Failed?.Invoke(new SetupException(SetupStage.HardwareScan,
                "Unerwarteter Fehler bei der Hardware-Analyse.", "Protokoll ansehen.", ex));
        }
    }
}
