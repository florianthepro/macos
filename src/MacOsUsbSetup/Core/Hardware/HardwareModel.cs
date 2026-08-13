namespace MacOsUsbSetup.Core.Hardware;

public enum CpuVendor { Intel, Amd, Unknown }

public enum GpuVendor { Intel, Amd, Nvidia, Unknown }

public enum FirmwareMode { Uefi, LegacyBios, Unknown }

/// <summary>
/// Processor as reported by the firmware/OS, with a resolved microarchitecture
/// label (e.g. "Coffee Lake", "Zen 3") used by the compatibility rules.
/// </summary>
public sealed record ProcessorInfo(
    CpuVendor Vendor,
    string Brand,
    int Family,
    int Model,
    int PhysicalCores,
    int LogicalCores,
    string Microarchitecture);

/// <summary>
/// A single graphics adapter with its PCI identity and a resolved GPU family
/// label (e.g. "Polaris", "Pascal", "UHD 630") used by the compatibility rules.
/// </summary>
public sealed record GraphicsInfo(
    GpuVendor Vendor,
    string Name,
    int PciVendorId,
    int PciDeviceId,
    string Family);

public sealed record HardwareInventory(
    ProcessorInfo Processor,
    IReadOnlyList<GraphicsInfo> GraphicsAdapters,
    FirmwareMode Firmware,
    ulong TotalMemoryBytes,
    string SystemManufacturer,
    string SystemModel);

public interface IHardwareScanner
{
    HardwareInventory Scan();
}
