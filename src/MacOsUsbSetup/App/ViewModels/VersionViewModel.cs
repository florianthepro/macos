using System.Collections.ObjectModel;
using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Hardware;

namespace MacOsUsbSetup.App.ViewModels;

/// <summary>Step 2: one clickable tile per macOS version that runs on this hardware.</summary>
public sealed class VersionViewModel : ViewModelBase
{
    public VersionViewModel(HardwareInventory hardware, IReadOnlyList<CompatibilityResult> results)
    {
        HardwareSummary = BuildSummary(hardware);
        foreach (var result in results.Where(r => r.Level != CompatibilityLevel.Unsupported))
            Tiles.Add(new VersionTileViewModel(result, release => ReleaseChosen?.Invoke(release)));
        BackCommand = new RelayCommand(_ => BackRequested?.Invoke());
    }

    public string Headline => "macOS-Version wählen";
    public string HardwareSummary { get; }
    public ObservableCollection<VersionTileViewModel> Tiles { get; } = new();
    public bool HasCompatible => Tiles.Count > 0;
    public string EmptyNotice => "Für diese Hardware wurde keine lauffähige macOS-Version gefunden.";
    public RelayCommand BackCommand { get; }

    public event Action<MacOsRelease>? ReleaseChosen;
    public event Action? BackRequested;

    private static string BuildSummary(HardwareInventory hardware)
    {
        var gpu = hardware.GraphicsAdapters.Count > 0
            ? string.Join(", ", hardware.GraphicsAdapters.Select(g => g.Name))
            : "keine Grafik erkannt";
        var ram = hardware.TotalMemoryBytes / 1_000_000_000d;
        return $"{hardware.Processor.Brand}  ·  {gpu}  ·  {ram:0} GB RAM";
    }
}

public sealed class VersionTileViewModel : ViewModelBase
{
    public VersionTileViewModel(CompatibilityResult result, Action<MacOsRelease> onSelect)
    {
        Release = result.Release;
        IsExperimental = result.Level == CompatibilityLevel.Experimental;
        Title = $"macOS {result.Release.Name}";
        Version = result.Release.MarketingVersion;
        Badge = IsExperimental ? "EXPERIMENTELL" : "EMPFOHLEN";
        Notes = string.Join(Environment.NewLine, result.Notes);
        SelectCommand = new RelayCommand(_ => onSelect(result.Release));
    }

    public MacOsRelease Release { get; }
    public bool IsExperimental { get; }
    public string Title { get; }
    public string Version { get; }
    public string Badge { get; }
    public string Notes { get; }
    public bool HasNotes => Notes.Length > 0;
    public RelayCommand SelectCommand { get; }
}
