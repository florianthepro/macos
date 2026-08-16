using System.IO;
using System.Net.Http;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Download;
using MacOsUsbSetup.Core.Efi;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.Recovery;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.Core.Setup;

/// <summary>
/// Runs the whole build in order: prepare the USB, write the EFI, then download and verify the
/// macOS recovery. For an offline plan it also downloads the full installer onto the data
/// partition and drops the recovery-side install helper. Stage progress is mapped onto one bar.
/// </summary>
public sealed class UsbBuildJob
{
    // Raw UnPlugged.command (CorpNewt): reconstructs the installer app from InstallAssistant.pkg in
    // the recovery Terminal and launches it — the maintained tool for exactly this offline flow.
    private const string UnPluggedUrl = "https://raw.githubusercontent.com/corpnewt/UnPlugged/main/UnPlugged.command";

    private const double PrepareEnd = 0.05;
    private const double EfiEnd = 0.10;
    private const double LookupEnd = 0.12;

    private readonly IDiskPreparer _preparer;
    private readonly IEfiInstaller _efi;
    private readonly IRecoveryImageService _recovery;
    private readonly IInstallAssistantService _installer;
    private readonly EfiAssets _assets;

    public UsbBuildJob(
        IDiskPreparer preparer, IEfiInstaller efi, IRecoveryImageService recovery,
        IInstallAssistantService installer, EfiAssets assets)
    {
        _preparer = preparer;
        _efi = efi;
        _recovery = recovery;
        _installer = installer;
        _assets = assets;
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

        // Reserve most of the bar for the full installer when offline (it dwarfs the recovery).
        var recoveryEnd = plan.Offline ? 0.30 : 0.99;

        Report(SetupStage.UsbPreparation, 0.01, $"USB wird vorbereitet: {plan.Target.Model}");
        var prepareLog = new Progress<string>(line => Report(SetupStage.UsbPreparation, PrepareEnd * 0.6, line));
        var volume = await _preparer.PrepareAsync(plan.Target, plan.Offline, prepareLog, ct);
        Report(SetupStage.UsbPreparation, PrepareEnd, $"Volume bereit: {volume.RootPath} ({volume.VolumeLabel})");

        Report(SetupStage.EfiInstallation, PrepareEnd + 0.01, "EFI und OpenCore werden geschrieben");
        var efiLog = new Progress<string>(line => Report(SetupStage.EfiInstallation, (PrepareEnd + EfiEnd) / 2, line));
        await _efi.InstallAsync(volume, hardware, plan.Release, efiLog, ct);
        Report(SetupStage.EfiInstallation, EfiEnd, "EFI geschrieben");

        Report(SetupStage.RecoveryLookup, EfiEnd + 0.01, $"Recovery-Quelle für macOS {plan.Release.Name} wird abgefragt");
        var image = await _recovery.ResolveAsync(plan.Release, ct);
        Report(SetupStage.RecoveryLookup, LookupEnd, "Download-Freigabe erhalten");

        var recoveryDir = Path.Combine(volume.RootPath, "com.apple.recovery.boot");
        var recoveryLog = new Progress<DownloadProgress>(p => Report(SetupStage.RecoveryDownload,
            LookupEnd + (p.Fraction ?? 0) * (recoveryEnd - LookupEnd),
            $"{p.FileName}: {p.BytesReceived / 1_000_000d:0} MB{Total(p)}"));
        await _recovery.DownloadAsync(image, recoveryDir, recoveryLog, ct);

        if (plan.Offline)
            await AddOfflineInstallerAsync(plan, volume, recoveryEnd, Report, ct);

        WriteStartMe(volume);

        Report(SetupStage.Verification, 1.0, "Fertig - der USB-Stick ist bootfähig.");
    }

    // The single post-install helper (plus the keyboard layout it prefers locally) goes onto the
    // stick root so the user can double-click it from Finder after the first macOS boot.
    private void WriteStartMe(PreparedVolume volume)
    {
        var roots = new List<string> { volume.RootPath };
        if (volume.DataRoot is { } dataRoot)
            roots.Add(dataRoot);
        foreach (var root in roots)
        {
            try
            {
                if (_assets.StartMeScript is { } startMe && File.Exists(startMe))
                    File.Copy(startMe, Path.Combine(root, "start-me.command"), overwrite: true);
                if (_assets.KeyboardLayoutFile is { } layout && File.Exists(layout))
                    File.Copy(layout, Path.Combine(root, "Windows-German.keylayout"), overwrite: true);
            }
            catch (Exception ex)
            {
                Log.Warn($"start-me.command konnte nicht nach {root} kopiert werden: {ex.Message}");
            }
        }
    }

    // Downloads the full installer onto the ExFAT data partition and drops the recovery-side
    // helper (UnPlugged.command) plus a German how-to, so the install needs no network.
    private async Task AddOfflineInstallerAsync(
        InstallPlan plan, PreparedVolume volume, double recoveryEnd, Action<SetupStage, double, string> report, CancellationToken ct)
    {
        if (volume.DataRoot is null)
            throw new SetupException(SetupStage.RecoveryDownload,
                "Datenpartition für den Offline-Installer fehlt.", "Setup erneut ausführen.");

        report(SetupStage.RecoveryLookup, recoveryEnd, "Voll-Installer wird bei Apple gesucht");
        var info = await _installer.ResolveAsync(plan.Release, ct);

        var installLog = new Progress<DownloadProgress>(p => report(SetupStage.RecoveryDownload,
            recoveryEnd + (p.Fraction ?? 0) * (0.98 - recoveryEnd),
            $"InstallAssistant.pkg: {p.BytesReceived / 1_000_000d:0} MB{Total(p)}"));
        await _installer.DownloadAsync(info, volume.DataRoot, installLog, ct);

        report(SetupStage.RecoveryDownload, 0.98, "Installer-Hilfsskript wird abgelegt");
        await WriteHelpersAsync(plan, volume.DataRoot, info, ct);
    }

    private async Task WriteHelpersAsync(InstallPlan plan, string dataRoot, InstallAssistantInfo info, CancellationToken ct)
    {
        // Primary: the non-interactive one-command installer (auto-formats, no questions).
        if (_assets.OfflineInstallScript is { } script && File.Exists(script))
        {
            try { File.Copy(script, Path.Combine(dataRoot, "offline-install.command"), overwrite: true); }
            catch (Exception ex) when (ex is not OperationCanceledException) { Log.Warn($"offline-install.command: {ex.Message}"); }
        }
        // Fallback: CorpNewt UnPlugged (interactive), best-effort.
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
            var unplugged = await http.GetStringAsync(UnPluggedUrl, ct);
            await File.WriteAllTextAsync(Path.Combine(dataRoot, "UnPlugged.command"), unplugged, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Log.Warn($"UnPlugged.command konnte nicht geladen werden: {ex.Message}");
        }
        await File.WriteAllTextAsync(Path.Combine(dataRoot, "INSTALL.txt"), InstallReadme(plan, info), ct);
    }

    private static string InstallReadme(InstallPlan plan, InstallAssistantInfo info) =>
        $"""
         Offline-Installation von macOS {plan.Release.Name} ({info.Version})
         =================================================================

         Dieser Stick enthält den KOMPLETTEN Installer - es wird KEIN Internet benötigt.

         1. Stick booten, im OpenCore-Menü "macOS Base System" wählen.
         2. Menüleiste: Dienstprogramme -> Terminal öffnen. Zwei Zeilen:

              cd "/Volumes/{DataLabelForReadme}"
              bash UnPlugged.command

            (Der bewährte Weg. Vorher im Festplattendienstprogramm die interne
            Platte als APFS "Macintosh HD" löschen, falls UnPlugged danach fragt.)

            Automatische Alternative (formatiert selbst, keine Rückfragen,
            10-s-Countdown):
              bash "/Volumes/{DataLabelForReadme}/offline-install.command"
            Mehrere interne Platten? Ziel angeben:  ... offline-install.command /dev/disk0

         3. Der Rechner startet danach neu. Stick EINGESTECKT LASSEN. WICHTIG:
            Erscheint wieder das Boot-Menü, den NEUEN Eintrag "macOS Installer"
            wählen - NICHT "macOS Base System"! Bei jedem weiteren Neustart
            wiederholen ("macOS Installer", später "Macintosh HD"), bis der
            Willkommensassistent erscheint.

         4. Nach dem ersten Anmelden: auf dem Stick "start-me.command" doppelklicken.
            Das kopiert OpenCore auf die interne Platte (bootet danach OHNE Stick)
            und richtet Tastatur/Feinschliff ein. Danach Stick abziehen.

         Nur bei macOS Sonoma/Sequoia, falls "{DataLabelForReadme}" fehlt:
              diskutil list physical
              mkdir "/Volumes/{DataLabelForReadme}"
              /sbin/mount_exfat /dev/diskXsY "/Volumes/{DataLabelForReadme}"

         Alternative (interaktiv, von CorpNewt): bash "/Volumes/{DataLabelForReadme}/UnPlugged.command"

         Der Installer wurde von Apple geladen: {info.Title} {info.Version}
         """;

    private const string DataLabelForReadme = "MACOS-DATA";

    private static string Total(DownloadProgress p) =>
        p.TotalBytes is > 0 ? $" / {p.TotalBytes.Value / 1_000_000d:0} MB" : "";
}
