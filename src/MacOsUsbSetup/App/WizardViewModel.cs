using MacOsUsbSetup.App.Mvvm;
using MacOsUsbSetup.App.ViewModels;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.Setup;

namespace MacOsUsbSetup.App;

/// <summary>Drives the linear flow scan → version → USB → write → done, plus the error page.</summary>
public sealed class WizardViewModel : ViewModelBase
{
    private readonly SetupServices _services = new();

    private HardwareInventory? _hardware;
    private IReadOnlyList<CompatibilityResult> _results = Array.Empty<CompatibilityResult>();
    private ViewModelBase _currentPage = null!;

    public WizardViewModel() => ShowScan();

    public ViewModelBase CurrentPage
    {
        get => _currentPage;
        private set => Set(ref _currentPage, value);
    }

    private void ShowScan()
    {
        var scan = new ScanViewModel(_services);
        scan.Completed += (hardware, results) =>
        {
            _hardware = hardware;
            _results = results;
            ShowVersions();
        };
        scan.Failed += error => ShowError(error, ShowScan);
        CurrentPage = scan;
        _ = scan.RunAsync();
    }

    private void ShowVersions()
    {
        var versions = new VersionViewModel(_hardware!, _results);
        versions.ReleaseChosen += ShowUsb;
        versions.BackRequested += ShowScan;
        CurrentPage = versions;
    }

    private void ShowUsb(MacOsRelease release)
    {
        var usb = new UsbViewModel(_services);
        usb.DiskChosen += disk => ShowWrite(new InstallPlan(release, disk));
        usb.BackRequested += ShowVersions;
        CurrentPage = usb;
    }

    private void ShowWrite(InstallPlan plan)
    {
        var write = new WriteViewModel(_services, plan, _hardware!);
        write.Completed += () => ShowDone(plan);
        write.Failed += error => ShowError(error, () => ShowUsb(plan.Release));
        CurrentPage = write;
        _ = write.RunAsync();
    }

    private void ShowDone(InstallPlan plan) => CurrentPage = new DoneViewModel(plan, ShowScan);

    private void ShowError(SetupException error, Action back) => CurrentPage = new ErrorViewModel(error, back);
}
