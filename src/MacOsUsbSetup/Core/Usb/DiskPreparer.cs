using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Text;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Usb;

/// <summary>
/// Wipes a USB disk and lays down a single bootable FAT32 volume via diskpart
/// scripting. FAT32 through diskpart is capped at 32 GB, so oversized sticks get
/// a 32 GB partition and leave the remainder unallocated (sufficient for an
/// installer). All faults surface as <see cref="SetupException"/>.
/// </summary>
public sealed class DiskPreparer : IDiskPreparer
{
    private const string VolumeLabel = "MACOS-USB";
    private const ulong MinimumSizeBytes = 7_000_000_000;
    private const ulong Fat32CapBytes = 32_000_000_000;
    private const int Fat32PartitionSizeMb = 32000;
    private const string StorageScope = @"\\.\root\Microsoft\Windows\Storage";

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
            throw new SetupException(SetupStage.UsbPreparation, "USB-Datenträger zu klein (mindestens 8 GB erforderlich).");
    }

    private static PreparedVolume Prepare(UsbDisk disk, IProgress<string> log, CancellationToken ct)
    {
        Log.Info($"USB-Datenträger {disk.DiskNumber} wird vorbereitet ({disk.Model}, {disk.SizeGigabytes:0.#} GB).");

        RunDiskpart(disk, log, ct);

        var letter = ResolveDriveLetter(disk.DiskNumber, ct);
        log.Report($"Laufwerk {letter}: zugewiesen.");
        Log.Info($"USB-Datenträger {disk.DiskNumber} formatiert, Laufwerk {letter}:.");

        return new PreparedVolume($"{letter}:\\", VolumeLabel, disk.DiskNumber);
    }

    private static void RunDiskpart(UsbDisk disk, IProgress<string> log, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        var scriptPath = Path.Combine(Path.GetTempPath(), $"macos-usb-diskpart-{Guid.NewGuid():N}.txt");
        try
        {
            File.WriteAllText(scriptPath, BuildScript(disk), new UTF8Encoding(false));

            log.Report($"Datenträger {disk.DiskNumber} wird bereinigt.");
            log.Report("GPT-Partitionstabelle wird angelegt.");
            log.Report($"FAT32-Partition wird erstellt und als \"{VolumeLabel}\" formatiert.");

            var (exitCode, output) = Execute(scriptPath, ct);

            if (exitCode != 0 || ContainsError(output))
            {
                Log.Error($"diskpart schlug fehl (Exit {exitCode}): {output}");
                throw new SetupException(
                    SetupStage.UsbPreparation,
                    output.Trim().Length == 0 ? $"diskpart beendet mit Code {exitCode}." : output.Trim(),
                    "USB-Datenträger neu einstecken und Setup als Administrator starten.");
            }

            log.Report("Formatierung abgeschlossen.");
        }
        finally
        {
            try { File.Delete(scriptPath); }
            catch (Exception ex) { Log.Warn($"diskpart-Skript konnte nicht gelöscht werden: {ex.Message}"); }
        }
    }

    private static string BuildScript(UsbDisk disk)
    {
        var createPartition = disk.SizeBytes <= Fat32CapBytes
            ? "create partition primary"
            : $"create partition primary size={Fat32PartitionSizeMb}";

        var builder = new StringBuilder();
        builder.AppendLine($"select disk {disk.DiskNumber}");
        builder.AppendLine("clean");
        builder.AppendLine("convert gpt");
        builder.AppendLine(createPartition);
        builder.AppendLine($"format fs=fat32 quick label=\"{VolumeLabel}\"");
        builder.AppendLine("assign");
        return builder.ToString();
    }

    private static (int ExitCode, string Output) Execute(string scriptPath, CancellationToken ct)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "diskpart.exe",
            Arguments = $"/s \"{scriptPath}\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        try
        {
            using var process = Process.Start(startInfo)
                ?? throw new SetupException(
                    SetupStage.UsbPreparation,
                    "diskpart.exe konnte nicht gestartet werden.",
                    "USB-Datenträger neu einstecken und Setup als Administrator starten.");

            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();

            var output = string.Concat(stdout, stderr).Trim();
            return (process.ExitCode, output);
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new SetupException(
                SetupStage.UsbPreparation,
                "diskpart konnte nicht ausgeführt werden.",
                "USB-Datenträger neu einstecken und Setup als Administrator starten.",
                ex);
        }
    }

    private static char ResolveDriveLetter(int diskNumber, CancellationToken ct)
    {
        const int attempts = 10;
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            ct.ThrowIfCancellationRequested();

            var letter = QueryDriveLetter(diskNumber);
            if (letter != '\0')
                return letter;

            Thread.Sleep(500);
        }

        throw new SetupException(
            SetupStage.UsbPreparation,
            "Formatiertes Volume wurde nicht gefunden.",
            "USB neu verbinden.");
    }

    private static char QueryDriveLetter(int diskNumber)
    {
        try
        {
            var scope = new ManagementScope(StorageScope);
            scope.Connect();

            var query = new ObjectQuery(
                $"SELECT DriveLetter FROM MSFT_Partition WHERE DiskNumber = {diskNumber}");

            using var searcher = new ManagementObjectSearcher(scope, query);

            foreach (var partition in searcher.Get().Cast<ManagementObject>())
            {
                var value = partition["DriveLetter"];
                if (value is null)
                    continue;

                var letter = (char)Convert.ToUInt16(value, CultureInfo.InvariantCulture);
                if (letter != '\0')
                    return letter;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Laufwerksbuchstabe konnte nicht abgefragt werden: {ex.Message}");
        }

        return '\0';
    }

    private static bool ContainsError(string output) =>
        output.Contains("error", StringComparison.OrdinalIgnoreCase)
        || output.Contains("Fehler", StringComparison.OrdinalIgnoreCase);
}
