using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.Core.Setup;

/// <summary>
/// What the user chose: a release to install onto a target disk. When <see cref="Offline"/> is
/// set, the full macOS installer is written to a second data partition so the install needs no
/// network (macOS 11+ only).
/// </summary>
public sealed record InstallPlan(MacOsRelease Release, UsbDisk Target, bool Offline = false);

/// <summary>
/// A single progress tick for the whole build. <see cref="Fraction"/> is the
/// overall 0..1 completion across all stages, not the current stage alone.
/// </summary>
public sealed record ProgressReport(SetupStage Stage, double Fraction, string Message);
