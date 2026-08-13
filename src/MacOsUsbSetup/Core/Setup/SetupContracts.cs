using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.Core.Setup;

/// <summary>What the user chose: a release to install onto a target disk.</summary>
public sealed record InstallPlan(MacOsRelease Release, UsbDisk Target);

/// <summary>
/// A single progress tick for the whole build. <see cref="Fraction"/> is the
/// overall 0..1 completion across all stages, not the current stage alone.
/// </summary>
public sealed record ProgressReport(SetupStage Stage, double Fraction, string Message);
