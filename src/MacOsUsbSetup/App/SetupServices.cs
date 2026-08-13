using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Efi;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.Recovery;
using MacOsUsbSetup.Core.Setup;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.App;

/// <summary>Single place that wires the concrete core services together.</summary>
public sealed class SetupServices
{
    private readonly EfiAssets _efiAssets = new();

    public SetupServices()
    {
        EfiInstaller = new EfiInstaller(_efiAssets, new OpenCoreConfigBuilder(_efiAssets));
    }

    public IHardwareScanner HardwareScanner { get; } = new HardwareScanner();
    public ICompatibilityEvaluator Compatibility { get; } = new CompatibilityEvaluator();
    public IUsbDiskEnumerator UsbEnumerator { get; } = new UsbDiskEnumerator();
    public IDiskPreparer DiskPreparer { get; } = new DiskPreparer();
    public IRecoveryImageService Recovery { get; } = new AppleRecoveryClient();
    public IEfiInstaller EfiInstaller { get; }

    public UsbBuildJob CreateBuildJob() => new(DiskPreparer, EfiInstaller, Recovery);
}
