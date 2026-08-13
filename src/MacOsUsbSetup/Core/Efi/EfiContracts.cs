using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.Core.Efi;

public interface IEfiInstaller
{
    /// <summary>
    /// Writes a complete EFI/ tree (OpenCore, drivers, base kexts) onto the
    /// prepared volume and generates a config.plist tailored to
    /// <paramref name="hardware"/> and <paramref name="release"/>.
    /// </summary>
    Task InstallAsync(
        PreparedVolume volume,
        HardwareInventory hardware,
        MacOsRelease release,
        IProgress<string> log,
        CancellationToken ct);
}
