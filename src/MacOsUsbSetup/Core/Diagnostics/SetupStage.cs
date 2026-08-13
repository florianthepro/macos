namespace MacOsUsbSetup.Core.Diagnostics;

public enum SetupStage
{
    HardwareScan,
    Compatibility,
    RecoveryLookup,
    RecoveryDownload,
    UsbPreparation,
    EfiInstallation,
    Verification
}
