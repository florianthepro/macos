using System.IO;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Download;
using MacOsUsbSetup.Core.Efi;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.Recovery;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.Core.Setup;

/// <summary>
/// Runs the whole build in order: prepare the USB, write the EFI, then download
/// and verify the macOS recovery. Stage progress is mapped onto one overall bar.
/// </summary>
public sealed class UsbBuildJob
{
    private const double PrepareEnd  = 0.08;
    private const double EfiEnd  = 0.15;
    private const double LookupEnd  = 0.18;
    private const double DownloadEnd = 0.99;

    private readonly IDiskPreparer _preparer;
    private readonly IEfiInstaller _efi;
    private readonly IRecoveryImageService _recovery;

    public UsbBuildJob(IDiskPreparer preparer, IEfiInstaller efi, IRecoveryImageService recovery)
    {
        _preparer = preparer;
        _efi = efi;
        _recovery = recovery;
    }

    public async Task RunAsync(
        InstallPlan plan,
        HardwareInventory hardware,
        IProgress<ProgressReport> progress,
        CancellationToken ct)
    {
        void Report(SetupStage stage, double fraction, string message)
        {
            progress.Report(new ProgressReport(stage, fraction, message));
            Log.Info(message);
        }

        Report(SetupStage.UsbPreparation, 0.01, $"USB wird vorbereitet: {plan.Target.Model}");
        var prepareLog = new Progress<string>(line => Report(SetupStage.UsbPreparation, PrepareEnd * 0.6, line));
        var volume = await _preparer.PrepareAsync(plan.Target, prepareLog, ct);
        Report(SetupStage.UsbPreparation, PrepareEnd, $"Volume bereit: {volume.RootPath} ({volume.VolumeLabel})");

        Report(SetupStage.EfiInstallation, PrepareEnd + 0.01, "EFI und OpenCore werden geschrieben");
        var efiLog = new Progress<string>(line => Report(SetupStage.EfiInstallation, (PrepareEnd + EfiEnd) / 2, line));
        await _efi.InstallAsync(volume, hardware, plan.Release, efiLog, ct);
        Report(SetupStage.EfiInstallation, EfiEnd, "EFI geschrieben");

        Report(SetupStage.RecoveryLookup, EfiEnd + 0.01, $"Recovery-Quelle für macOS {plan.Release.Name} wird abgefragt");
        var image = await _recovery.ResolveAsync(plan.Release, ct);
        Report(SetupStage.RecoveryLookup, LookupEnd, "Download-Freigabe erhalten");

        var recoveryDir = Path.Combine(volume.RootPath, "com.apple.recovery.boot");
        var downloadLog = new Progress<DownloadProgress>(p =>
        {
            var fraction = LookupEnd + (p.Fraction ?? 0) * (DownloadEnd - LookupEnd);
            var received = p.BytesReceived / 1_000_000d;
            var total = p.TotalBytes is > 0 ? $" / {p.TotalBytes.Value / 1_000_000d:0} MB" : "";
            Report(SetupStage.RecoveryDownload, fraction, $"{p.FileName}: {received:0} MB{total}");
        });
        await _recovery.DownloadAsync(image, recoveryDir, downloadLog, ct);

        Report(SetupStage.Verification, 1.0, "Fertig - der USB-Stick ist bootfähig.");
    }
}
