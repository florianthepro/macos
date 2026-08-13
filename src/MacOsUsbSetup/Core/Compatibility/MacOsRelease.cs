namespace MacOsUsbSetup.Core.Compatibility;

/// <summary>
/// A macOS release the Apple recovery service can currently serve.
/// <see cref="RecoveryBoardId"/> is the board identifier passed to the recovery
/// endpoint to obtain this release; <see cref="RecoveryOsType"/> is "default"
/// for a pinned version or "latest" for the newest release the board offers.
/// </summary>
public sealed record MacOsRelease(
    string Name,
    string MarketingVersion,
    string RecoveryVersion,
    int DarwinMajor,
    int Ordinal,
    string RecoveryBoardId,
    string RecoveryOsType,
    string PreferredDesktopSmbios,
    string PreferredLaptopSmbios);
