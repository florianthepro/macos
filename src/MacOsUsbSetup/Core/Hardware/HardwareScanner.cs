using System.Globalization;
using System.Management;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Hardware;

/// <summary>
/// Reads the local machine's processor, graphics adapters, firmware mode and
/// system identity via WMI (root\cimv2) plus a single kernel32 P/Invoke.
/// A missing CPU is fatal; graphics and firmware faults are tolerated.
/// </summary>
public sealed class HardwareScanner : IHardwareScanner
{
    private static readonly Regex FamilyModelPattern =
        new(@"Family\s+(?<family>\d+).*?Model\s+(?<model>\d+)",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex PciIdPattern =
        new(@"(?<key>VEN|DEV)_(?<value>[0-9A-Fa-f]{4})", RegexOptions.Compiled);

    [DllImport("kernel32.dll")]
    private static extern bool GetFirmwareType(out uint firmwareType);

    public HardwareInventory Scan()
    {
        Log.Info("Hardware-Scan gestartet.");

        var processor = ReadProcessor();
        var graphics = ReadGraphics();
        var firmware = ReadFirmware();
        var (manufacturer, model, memory) = ReadSystem();

        Log.Info($"Hardware-Scan abgeschlossen: {processor.Brand}, {graphics.Count} Grafik-Adapter, Firmware {firmware}.");

        return new HardwareInventory(processor, graphics, firmware, memory, manufacturer, model);
    }

    private static ProcessorInfo ReadProcessor()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT Name, Manufacturer, Caption, Description, NumberOfCores, NumberOfLogicalProcessors FROM Win32_Processor");

            var cpu = searcher.Get().Cast<ManagementObject>().FirstOrDefault()
                      ?? throw new InvalidOperationException("Win32_Processor lieferte kein Ergebnis.");

            var brand = GetString(cpu, "Name").Trim();
            var vendor = ParseCpuVendor(GetString(cpu, "Manufacturer"));
            var (family, model) = ParseFamilyModel(GetString(cpu, "Caption"), GetString(cpu, "Description"));
            var physicalCores = GetInt(cpu, "NumberOfCores");
            var logicalCores = GetInt(cpu, "NumberOfLogicalProcessors");
            var microarchitecture = ResolveMicroarchitecture(vendor, family, model);

            return new ProcessorInfo(vendor, brand, family, model, physicalCores, logicalCores, microarchitecture);
        }
        catch (Exception ex)
        {
            Log.Error($"Prozessor konnte nicht ausgelesen werden: {ex.Message}");
            throw new SetupException(
                SetupStage.HardwareScan,
                "Hardware konnte nicht ausgelesen werden.",
                "WMI/Windows-Verwaltungsdienst prüfen und setup.exe als Administrator starten.",
                ex);
        }
    }

    private static IReadOnlyList<GraphicsInfo> ReadGraphics()
    {
        var adapters = new List<GraphicsInfo>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT Name, PNPDeviceID FROM Win32_VideoController");

            foreach (var controller in searcher.Get().Cast<ManagementObject>())
            {
                var pnpDeviceId = GetString(controller, "PNPDeviceID");
                var (vendorId, deviceId) = ParsePciId(pnpDeviceId);
                if (vendorId == 0 && deviceId == 0)
                    continue; // Microsoft Basic Display / virtuelle Adapter ohne VEN_/DEV_

                var vendor = ParseGpuVendor(vendorId);
                var name = GetString(controller, "Name").Trim();
                var family = ResolveGpuFamily(vendor, deviceId, name);

                adapters.Add(new GraphicsInfo(vendor, name, vendorId, deviceId, family));
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Grafik-Adapter konnten nicht vollständig ausgelesen werden: {ex.Message}");
        }

        return adapters;
    }

    private static FirmwareMode ReadFirmware()
    {
        try
        {
            if (GetFirmwareType(out var firmwareType))
            {
                return firmwareType switch
                {
                    1 => FirmwareMode.LegacyBios,
                    2 => FirmwareMode.Uefi,
                    _ => FirmwareMode.Unknown
                };
            }

            Log.Warn("GetFirmwareType schlug fehl; Firmware-Modus unbekannt.");
        }
        catch (Exception ex)
        {
            Log.Warn($"Firmware-Modus konnte nicht bestimmt werden: {ex.Message}");
        }

        return FirmwareMode.Unknown;
    }

    private static (string Manufacturer, string Model, ulong Memory) ReadSystem()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT Manufacturer, Model, TotalPhysicalMemory FROM Win32_ComputerSystem");

            var system = searcher.Get().Cast<ManagementObject>().FirstOrDefault();
            if (system is null)
            {
                Log.Warn("Win32_ComputerSystem lieferte kein Ergebnis.");
                return (string.Empty, string.Empty, 0);
            }

            return (
                GetString(system, "Manufacturer").Trim(),
                GetString(system, "Model").Trim(),
                GetUlong(system, "TotalPhysicalMemory"));
        }
        catch (Exception ex)
        {
            Log.Warn($"System-Identität konnte nicht ausgelesen werden: {ex.Message}");
            return (string.Empty, string.Empty, 0);
        }
    }

    private static CpuVendor ParseCpuVendor(string manufacturer) => manufacturer.Trim() switch
    {
        "GenuineIntel" => CpuVendor.Intel,
        "AuthenticAMD" => CpuVendor.Amd,
        _ => CpuVendor.Unknown
    };

    private static (int Family, int Model) ParseFamilyModel(string caption, string description)
    {
        foreach (var candidate in new[] { caption, description })
        {
            var match = FamilyModelPattern.Match(candidate);
            if (match.Success
                && int.TryParse(match.Groups["family"].Value, out var family)
                && int.TryParse(match.Groups["model"].Value, out var model))
            {
                return (family, model);
            }
        }

        return (0, 0);
    }

    private static (int VendorId, int DeviceId) ParsePciId(string pnpDeviceId)
    {
        var vendorId = 0;
        var deviceId = 0;

        foreach (Match match in PciIdPattern.Matches(pnpDeviceId))
        {
            var value = int.Parse(match.Groups["value"].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            if (match.Groups["key"].Value == "VEN")
                vendorId = value;
            else
                deviceId = value;
        }

        return (vendorId, deviceId);
    }

    private static GpuVendor ParseGpuVendor(int vendorId) => vendorId switch
    {
        0x8086 => GpuVendor.Intel,
        0x1002 or 0x1022 => GpuVendor.Amd,
        0x10DE => GpuVendor.Nvidia,
        _ => GpuVendor.Unknown
    };

    private static string ResolveMicroarchitecture(CpuVendor vendor, int family, int model)
    {
        var resolved = vendor switch
        {
            CpuVendor.Intel when family == 6 => IntelMicroarchitecture(model),
            CpuVendor.Amd => AmdMicroarchitecture(family),
            _ => null
        };

        return resolved ?? GenericMicroarchitecture(vendor, family, model);
    }

    private static string? IntelMicroarchitecture(int model) => model switch
    {
        42 or 58 => "Sandy Bridge/Ivy Bridge",
        60 or 69 or 70 => "Haswell",
        61 or 71 => "Broadwell",
        78 or 94 => "Skylake",
        142 or 158 => "Kaby Lake/Coffee Lake/Comet Lake",
        165 or 166 => "Comet Lake",
        140 or 141 => "Ice Lake/Tiger Lake",
        151 or 154 => "Alder Lake",
        183 => "Raptor Lake",
        _ => null
    };

    private static string? AmdMicroarchitecture(int family) => family switch
    {
        23 => "Zen/Zen+/Zen2",
        25 => "Zen 3/4",
        26 => "Zen 5",
        _ => null
    };

    private static string GenericMicroarchitecture(CpuVendor vendor, int family, int model)
    {
        var label = vendor switch
        {
            CpuVendor.Intel => "Intel",
            CpuVendor.Amd => "AMD",
            _ => "CPU"
        };

        return $"{label} Family {family} Model {model}";
    }

    private static string ResolveGpuFamily(GpuVendor vendor, int deviceId, string name)
    {
        var resolved = vendor switch
        {
            GpuVendor.Intel => IntelGpuFamily(deviceId),
            GpuVendor.Amd => AmdGpuFamily(deviceId),
            GpuVendor.Nvidia => NvidiaGpuFamily(deviceId),
            _ => null
        };

        return resolved ?? name;
    }

    private static string? IntelGpuFamily(int deviceId) => deviceId switch
    {
        >= 0x9B00 and <= 0x9BFF => "UHD Graphics",
        >= 0x3E00 and <= 0x3EFF => "UHD Graphics",
        >= 0x5900 and <= 0x59FF => "HD Graphics",
        >= 0x1900 and <= 0x193F => "HD Graphics",
        _ => null
    };

    private static string? AmdGpuFamily(int deviceId) => deviceId switch
    {
        >= 0x67C0 and <= 0x67FF => "Polaris",
        >= 0x6860 and <= 0x69FF => "Vega",
        >= 0x7310 and <= 0x73FF => "Navi",
        _ => null
    };

    private static string? NvidiaGpuFamily(int deviceId) => deviceId switch
    {
        >= 0x0FC0 and <= 0x11FF => "Kepler",
        >= 0x1340 and <= 0x13FF => "Maxwell",
        >= 0x1B00 and <= 0x1DFF => "Pascal",
        >= 0x1E00 and <= 0x1FFF => "Turing",
        _ => null
    };

    private static string GetString(ManagementBaseObject source, string property) =>
        source[property] as string ?? string.Empty;

    private static int GetInt(ManagementBaseObject source, string property)
    {
        var value = source[property];
        return value is null ? 0 : Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }

    private static ulong GetUlong(ManagementBaseObject source, string property)
    {
        var value = source[property];
        return value is null ? 0 : Convert.ToUInt64(value, CultureInfo.InvariantCulture);
    }
}
