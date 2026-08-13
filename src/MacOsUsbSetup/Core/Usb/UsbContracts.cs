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

/// <summary>The formatted, mounted target ready to receive the EFI and recovery.</summary>
public sealed record PreparedVolume(string RootPath, string VolumeLabel, int DiskNumber);

public interface IUsbDiskEnumerator
{
    IReadOnlyList<UsbDisk> Enumerate();
}

public interface IDiskPreparer
{
    /// <summary>
    /// Wipes the disk, creates a single bootable FAT32 volume and returns it
    /// mounted. Throws <see cref="Diagnostics.SetupException"/> on any failure.
    /// </summary>
    Task<PreparedVolume> PrepareAsync(UsbDisk disk, IProgress<string> log, CancellationToken ct);
}
