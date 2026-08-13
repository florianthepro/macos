namespace MacOsUsbSetup.Core.Usb;

/// <summary>
/// A physical disk offered as an install target. <see cref="IsSystemDisk"/>
/// marks the disk Windows is running from; such disks are never writable here.
/// </summary>
public sealed record UsbDisk(
    int DiskNumber,
    string Model,
    ulong SizeBytes,
    string BusType,
    bool IsRemovable,
    bool IsSystemDisk)
{
    public double SizeGigabytes => SizeBytes / 1_000_000_000d;
}

/// <summary>
/// The formatted, mounted target ready to receive the EFI and recovery. <see cref="DataRoot"/> is
/// the mounted second (ExFAT) partition when the offline installer was requested, else null.
/// </summary>
public sealed record PreparedVolume(string RootPath, string VolumeLabel, int DiskNumber, string? DataRoot = null);

public interface IUsbDiskEnumerator
{
    IReadOnlyList<UsbDisk> Enumerate();
}

public interface IDiskPreparer
{
    /// <summary>
    /// Wipes the disk and creates a bootable FAT32 volume, returned mounted. When
    /// <paramref name="offline"/> is set, a second ExFAT data partition is added (for the full
    /// installer) and exposed via <see cref="PreparedVolume.DataRoot"/>. Throws
    /// <see cref="Diagnostics.SetupException"/> on any failure.
    /// </summary>
    Task<PreparedVolume> PrepareAsync(UsbDisk disk, bool offline, IProgress<string> log, CancellationToken ct);
}
