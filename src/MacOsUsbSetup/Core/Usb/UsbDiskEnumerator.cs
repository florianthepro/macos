using System.Globalization;
using System.Management;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Usb;

/// <summary>
/// Lists USB disks eligible as install targets. The primary source is the
/// Storage namespace (root\Microsoft\Windows\Storage, MSFT_Disk); if that query
/// fails the enumerator falls back to Win32_DiskDrive. Only USB-attached disks
/// are returned; an empty result is a valid answer, never an error.
/// </summary>
public sealed class UsbDiskEnumerator : IUsbDiskEnumerator
{
    private const ushort UsbBusType = 7;
    private const string StorageScope = @"\\.\root\Microsoft\Windows\Storage";

    public IReadOnlyList<UsbDisk> Enumerate()
    {
        Log.Info("USB-Datenträger werden gesucht.");

        List<UsbDisk> disks;
        try
        {
            disks = FromStorageNamespace();
        }
        catch (Exception ex)
        {
            Log.Warn($"Storage-Namespace nicht verfügbar, Rückfall auf Win32_DiskDrive: {ex.Message}");
            disks = FromWin32DiskDrive();
        }

        disks.Sort((left, right) => left.DiskNumber.CompareTo(right.DiskNumber));
        Log.Info($"{disks.Count} USB-Datenträger gefunden.");
        return disks;
    }

    private static List<UsbDisk> FromStorageNamespace()
    {
        var scope = new ManagementScope(StorageScope);
        scope.Connect();

        var query = new ObjectQuery(
            "SELECT Number, Size, FriendlyName, BusType, IsSystem, IsBoot, IsReadOnly FROM MSFT_Disk");

        using var searcher = new ManagementObjectSearcher(scope, query);

        var disks = new List<UsbDisk>();
        foreach (var disk in searcher.Get().Cast<ManagementObject>())
        {
            var busType = GetUshort(disk, "BusType");
            if (busType != UsbBusType)
                continue;

            var size = GetUlong(disk, "Size");
            if (size == 0)
                continue;

            var number = (int)GetUint(disk, "Number");
            var model = GetString(disk, "FriendlyName").Trim();
            var isSystemDisk = GetBool(disk, "IsSystem") || GetBool(disk, "IsBoot");

            if (GetBool(disk, "IsReadOnly"))
                Log.Warn($"USB-Datenträger {number} ist schreibgeschützt.");

            disks.Add(new UsbDisk(number, model, size, MapBusType(busType), IsRemovable: true, isSystemDisk));
        }

        return disks;
    }

    private static List<UsbDisk> FromWin32DiskDrive()
    {
        var disks = new List<UsbDisk>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT DeviceID, Index, Model, Size, MediaType FROM Win32_DiskDrive WHERE InterfaceType='USB'");

            foreach (var disk in searcher.Get().Cast<ManagementObject>())
            {
                var size = GetUlong(disk, "Size");
                if (size == 0)
                    continue;

                var number = (int)GetUint(disk, "Index");
                var model = GetString(disk, "Model").Trim();

                disks.Add(new UsbDisk(number, model, size, "USB", IsRemovable: true, IsSystemDisk: false));
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Win32_DiskDrive-Rückfall lieferte kein Ergebnis: {ex.Message}");
        }

        return disks;
    }

    private static string MapBusType(ushort busType) => busType switch
    {
        7 => "USB",
        8 => "SD",
        17 => "NVMe",
        11 => "SATA",
        _ => $"Bus {busType}"
    };

    private static string GetString(ManagementBaseObject source, string property) =>
        source[property] as string ?? string.Empty;

    private static bool GetBool(ManagementBaseObject source, string property) =>
        source[property] is not null && Convert.ToBoolean(source[property], CultureInfo.InvariantCulture);

    private static ushort GetUshort(ManagementBaseObject source, string property)
    {
        var value = source[property];
        return value is null ? (ushort)0 : Convert.ToUInt16(value, CultureInfo.InvariantCulture);
    }

    private static uint GetUint(ManagementBaseObject source, string property)
    {
        var value = source[property];
        return value is null ? 0u : Convert.ToUInt32(value, CultureInfo.InvariantCulture);
    }

    private static ulong GetUlong(ManagementBaseObject source, string property)
    {
        var value = source[property];
        return value is null ? 0ul : Convert.ToUInt64(value, CultureInfo.InvariantCulture);
    }
}
