using System.Threading.Tasks;
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

    // Side-effect free: build the scan page but do not start scanning until Start().
    public WizardViewModel() => ShowScan(autoStart: false);

    public ViewModelBase CurrentPage
    {
        get => _currentPage;
        private set => Set(ref _currentPage, value);
    }

    /// <summary>Begins the hardware scan. Called once the window is shown.</summary>
    public void Start()
    {
        if (CurrentPage is ScanViewModel scan)
            FireAndForget(scan.RunAsync(), "Scan");
    }

    private void ShowScan(bool autoStart = true)
    {
        var scan = new ScanViewModel(_services);
        scan.Completed += (hardware, results) =>
        {
            _hardware = hardware;
            _results = results;
            ShowVersions();
        };
        scan.Failed += error => ShowError(error, () => ShowScan());
        CurrentPage = scan;
        if (autoStart)
            FireAndForget(scan.RunAsync(), "Scan");
    }

    private void ShowVersions()
    {
        var versions = new VersionViewModel(_hardware!, _results);
        versions.ReleaseChosen += ShowUsb;
        versions.BackRequested += () => ShowScan();
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
        FireAndForget(write.RunAsync(), "Write");
    }

    private void ShowDone(InstallPlan plan) => CurrentPage = new DoneViewModel(plan, () => ShowScan());

    private void ShowError(SetupException error, Action back) => CurrentPage = new ErrorViewModel(error, back);

    // A discarded fire-and-forget Task hides faults; route any fault to the crash reporter.
    private static void FireAndForget(Task task, string origin) =>
        task.ContinueWith(
            t => App.Report(t.Exception, origin),
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
}
