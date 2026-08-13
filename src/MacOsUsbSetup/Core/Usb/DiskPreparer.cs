using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Usb;

/// <summary>
/// Wipes a USB disk and lays down a bootable FAT32 volume. Any prior format is removed by
/// diskpart's <c>clean</c>, then an MBR primary FAT32 partition is created (removable UEFI media
/// boots from EFI\BOOT\BOOTx64.efi regardless of MBR/GPT, and MBR avoids the convert-gpt failure
/// on flash drives). For the offline installer a second ExFAT partition is added to hold the full
/// installer package. diskpart runs elevated so the app itself needs no admin rights.
/// </summary>
public sealed class DiskPreparer : IDiskPreparer
{
    private const string VolumeLabel = "MACOS-USB";
    private const string DataLabel = "MACOS-DATA";
    private const ulong MinimumSizeBytes = 8_000_000_000;
    // The full offline installer (InstallAssistant.pkg) is up to ~18 GB; leave room for the EFI
    // partition and slack, so require a genuine 32 GB-class stick.
    private const ulong OfflineMinimumSizeBytes = 24_000_000_000;
    private const ulong Fat32CapBytes = 32_000_000_000;
    private const int Fat32PartitionSizeMb = 32000;
    // EFI/recovery partition when offline: OpenCore (~100 MB) + BaseSystem recovery (~1.5 GB).
    private const int OfflineEfiPartitionSizeMb = 3000;

    public async Task<PreparedVolume> PrepareAsync(UsbDisk disk, bool offline, IProgress<string> log, CancellationToken ct)
    {
        Guard(disk, offline);
        return await Task.Run(() => Prepare(disk, offline, log, ct), ct).ConfigureAwait(false);
    }

    private static void Guard(UsbDisk disk, bool offline)
    {
        if (disk.IsSystemDisk)
            throw new SetupException(SetupStage.UsbPreparation, "Der Systemdatenträger kann nicht verwendet werden.");
        if (disk.BusType != "USB" && !disk.IsRemovable)
            throw new SetupException(SetupStage.UsbPreparation, "Nur USB-Datenträger sind zugelassen.");
        var minimum = offline ? OfflineMinimumSizeBytes : MinimumSizeBytes;
        if (disk.SizeBytes < minimum)
            throw new SetupException(SetupStage.UsbPreparation,
                $"USB-Datenträger zu klein ({disk.SizeGigabytes:0.#} GB). " +
                (offline ? "Für den Offline-Installer sind mindestens 32 GB nötig." : "Mindestens 8 GB erforderlich."));
    }

    private static PreparedVolume Prepare(UsbDisk disk, bool offline, IProgress<string> log, CancellationToken ct)
    {
        Log.Info($"USB {disk.DiskNumber} wird vorbereitet ({disk.Model}, {disk.SizeGigabytes:0.#} GB, offline={offline}).");
        log.Report(offline ? "USB-Datenträger wird partitioniert (FAT32 + ExFAT)" : "USB-Datenträger wird formatiert (FAT32)");
        RunDiskpart(disk, offline, ct);

        var root = ResolveVolumeRoot(VolumeLabel, ct);
        string? dataRoot = offline ? ResolveVolumeRoot(DataLabel, ct) : null;
        log.Report($"Volume bereit: {root}");
        Log.Info($"USB {disk.DiskNumber} formatiert: EFI={root} Daten={dataRoot ?? "-"}");
        return new PreparedVolume(root, VolumeLabel, disk.DiskNumber, dataRoot);
    }

    private static void RunDiskpart(UsbDisk disk, bool offline, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var script = Path.Combine(Path.GetTempPath(), $"macos-usb-{Guid.NewGuid():N}.txt");
        File.WriteAllText(script, BuildScript(disk, offline), new UTF8Encoding(false));
        try
        {
            var info = new ProcessStartInfo
            {
                FileName = "diskpart.exe",
                Arguments = $"/s \"{script}\"",
                UseShellExecute = true,          // required to elevate
                Verb = "runas",                  // request admin for this step only
                WindowStyle = ProcessWindowStyle.Hidden,
            };

            Process process;
            try
            {
                process = Process.Start(info) ?? throw new SetupException(
                    SetupStage.UsbPreparation, "diskpart konnte nicht gestartet werden.");
            }
            catch (Win32Exception ex) when (ex.NativeErrorCode == 1223) // ERROR_CANCELLED
            {
                throw new SetupException(SetupStage.UsbPreparation,
                    "Administratorrechte wurden abgelehnt.",
                    "Zum Formatieren des USB-Datenträgers bei der Windows-Abfrage auf Ja klicken.");
            }

            process.WaitForExit();
            Log.Info($"diskpart beendet (Code {process.ExitCode}).");
        }
        finally
        {
            try { File.Delete(script); } catch { /* temp cleanup is best-effort */ }
        }
    }

    private static string BuildScript(UsbDisk disk, bool offline)
    {
        var script = new StringBuilder();
        script.AppendLine($"select disk {disk.DiskNumber}");
        script.AppendLine("clean");

        if (offline)
        {
            // Two MBR primaries: a bootable FAT32 (EFI + recovery) and an ExFAT data partition for
            // the ~12-18 GB installer, which cannot live on FAT32 (4 GB file limit). MBR matches the
            // proven single-partition layout and avoids the convert-gpt failure on flash drives.
            script.AppendLine($"create partition primary size={OfflineEfiPartitionSizeMb}");
            script.AppendLine("active");
            script.AppendLine($"format fs=fat32 quick label=\"{VolumeLabel}\"");
            script.AppendLine("assign");
            script.AppendLine("create partition primary");
            script.AppendLine($"format fs=exfat quick label=\"{DataLabel}\"");
            script.AppendLine("assign");
            return script.ToString();
        }

        script.AppendLine(disk.SizeBytes <= Fat32CapBytes
            ? "create partition primary"
            : $"create partition primary size={Fat32PartitionSizeMb}");
        script.AppendLine("active");
        script.AppendLine($"format fs=fat32 quick label=\"{VolumeLabel}\"");
        script.AppendLine("assign");
        return script.ToString();
    }

    // Locate the freshly formatted volume by its label. Uses DriveInfo (no elevation
    // and no admin-only Storage WMI), so it works from the non-elevated app.
    private static string ResolveVolumeRoot(string label, CancellationToken ct)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            foreach (var drive in DriveInfo.GetDrives())
            {
                try
                {
                    if (drive.IsReady && string.Equals(drive.VolumeLabel, label, StringComparison.OrdinalIgnoreCase))
                        return drive.RootDirectory.FullName;
                }
                catch { /* drive not mounted yet */ }
            }
            Thread.Sleep(500);
        }

        throw new SetupException(SetupStage.UsbPreparation,
            "USB-Datenträger konnte nicht formatiert werden.",
            "Anderen USB-Anschluss oder Datenträger verwenden und Setup erneut ausführen.");
    }
}
