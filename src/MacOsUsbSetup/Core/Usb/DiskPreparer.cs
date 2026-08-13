using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Usb;

/// <summary>
/// Wipes a USB disk and lays down a single bootable FAT32 volume. Any prior
/// format is removed by diskpart's <c>clean</c>, then an MBR primary FAT32
/// partition is created (removable UEFI media boots from EFI\BOOT\BOOTx64.efi
/// regardless of MBR/GPT, and MBR avoids the convert-gpt failure on flash
/// drives). diskpart runs elevated so the app itself needs no admin rights.
/// </summary>
public sealed class DiskPreparer : IDiskPreparer
{
    private const string VolumeLabel = "MACOS-USB";
    private const ulong MinimumSizeBytes = 8_000_000_000;
    private const ulong Fat32CapBytes = 32_000_000_000;
    private const int Fat32PartitionSizeMb = 32000;

    public async Task<PreparedVolume> PrepareAsync(UsbDisk disk, IProgress<string> log, CancellationToken ct)
    {
        Guard(disk);
        return await Task.Run(() => Prepare(disk, log, ct), ct).ConfigureAwait(false);
    }

    private static void Guard(UsbDisk disk)
    {
        if (disk.IsSystemDisk)
            throw new SetupException(SetupStage.UsbPreparation, "Der Systemdatenträger kann nicht verwendet werden.");
        if (disk.BusType != "USB" && !disk.IsRemovable)
            throw new SetupException(SetupStage.UsbPreparation, "Nur USB-Datenträger sind zugelassen.");
        if (disk.SizeBytes < MinimumSizeBytes)
            throw new SetupException(SetupStage.UsbPreparation,
                $"USB-Datenträger zu klein ({disk.SizeGigabytes:0.#} GB). Mindestens 8 GB erforderlich.");
    }

    private static PreparedVolume Prepare(UsbDisk disk, IProgress<string> log, CancellationToken ct)
    {
        Log.Info($"USB {disk.DiskNumber} wird vorbereitet ({disk.Model}, {disk.SizeGigabytes:0.#} GB).");
        log.Report("USB-Datenträger wird formatiert (FAT32)");
        RunDiskpart(disk, ct);

        var root = ResolveVolumeRoot(ct);
        log.Report($"Volume bereit: {root}");
        Log.Info($"USB {disk.DiskNumber} formatiert: {root}");
        return new PreparedVolume(root, VolumeLabel, disk.DiskNumber);
    }

    private static void RunDiskpart(UsbDisk disk, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var script = Path.Combine(Path.GetTempPath(), $"macos-usb-{Guid.NewGuid():N}.txt");
        File.WriteAllText(script, BuildScript(disk), new UTF8Encoding(false));
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

    private static string BuildScript(UsbDisk disk)
    {
        var create = disk.SizeBytes <= Fat32CapBytes
            ? "create partition primary"
            : $"create partition primary size={Fat32PartitionSizeMb}";

        var script = new StringBuilder();
        script.AppendLine($"select disk {disk.DiskNumber}");
        script.AppendLine("clean");
        script.AppendLine(create);
        script.AppendLine("active");
        script.AppendLine($"format fs=fat32 quick label=\"{VolumeLabel}\"");
        script.AppendLine("assign");
        return script.ToString();
    }

    // Locate the freshly formatted volume by its label. Uses DriveInfo (no elevation
    // and no admin-only Storage WMI), so it works from the non-elevated app.
    private static string ResolveVolumeRoot(CancellationToken ct)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            foreach (var drive in DriveInfo.GetDrives())
            {
                try
                {
                    if (drive.IsReady && string.Equals(drive.VolumeLabel, VolumeLabel, StringComparison.OrdinalIgnoreCase))
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
