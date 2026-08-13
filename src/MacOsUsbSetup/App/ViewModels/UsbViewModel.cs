using System.Collections.ObjectModel;
using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.App.ViewModels;

/// <summary>Step 3: pick the target USB stick. The disk is erased entirely.</summary>
public sealed class UsbViewModel : ViewModelBase
{
    private readonly SetupServices _services;

    public UsbViewModel(SetupServices services)
    {
        _services = services;
        RefreshCommand = new RelayCommand(_ => Refresh());
        BackCommand = new RelayCommand(_ => BackRequested?.Invoke());
        Refresh();
    }

    public string Headline => "USB-Datenträger wählen";
    public string Warning => "Der gewählte Datenträger wird vollständig gelöscht.";
    public string EmptyNotice => "Kein USB-Datenträger gefunden. Stick einstecken und aktualisieren.";
    public ObservableCollection<UsbTileViewModel> Disks { get; } = new();
    public bool HasDisks => Disks.Count > 0;
    public RelayCommand RefreshCommand { get; }
    public RelayCommand BackCommand { get; }

    public event Action<UsbDisk>? DiskChosen;
    public event Action? BackRequested;

    private void Refresh()
    {
        Disks.Clear();
        try
        {
            foreach (var disk in _services.UsbEnumerator.Enumerate())
                Disks.Add(new UsbTileViewModel(disk, chosen => DiskChosen?.Invoke(chosen)));
        }
        catch (Exception ex)
        {
            Log.Warn($"USB-Erkennung fehlgeschlagen: {ex.Message}");
        }
        Raise(nameof(HasDisks));
    }
}

public sealed class UsbTileViewModel : ViewModelBase
{
    public UsbTileViewModel(UsbDisk disk, Action<UsbDisk> onSelect)
    {
        Disk = disk;
        Model = string.IsNullOrWhiteSpace(disk.Model) ? "USB-Datenträger" : disk.Model.Trim();
        Details = $"{disk.SizeGigabytes:0.#} GB  -  {disk.BusType}";
        SelectCommand = new RelayCommand(_ => onSelect(disk));
    }

    public UsbDisk Disk { get; }
    public string Model { get; }
    public string Details { get; }
    public RelayCommand SelectCommand { get; }
}
