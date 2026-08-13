using MacOsUsbSetup.Core.Hardware;

namespace MacOsUsbSetup.Core.Compatibility;

public enum CompatibilityLevel
{
    /// <summary>Runs on this hardware with the bundled configuration.</summary>
    Supported,

    /// <summary>Boots, but a listed constraint needs manual attention.</summary>
    Experimental,

    /// <summary>A hard blocker prevents this release from running here.</summary>
    Unsupported
}

/// <summary>
/// Verdict for one release on the scanned hardware. <see cref="Notes"/> holds the
/// technical reasons behind the level (shown verbatim on the tile).
/// </summary>
public sealed record CompatibilityResult(
    MacOsRelease Release,
    CompatibilityLevel Level,
    IReadOnlyList<string> Notes);

public interface ICompatibilityEvaluator
{
    /// <summary>One result per known release, most recent first.</summary>
    IReadOnlyList<CompatibilityResult> Evaluate(HardwareInventory hardware);
}
