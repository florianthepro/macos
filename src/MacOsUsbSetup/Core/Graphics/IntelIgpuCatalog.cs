namespace MacOsUsbSetup.Core.Graphics;

/// <summary>Extra framebuffer memory patch an entry needs when the firmware locks DVMT-prealloc.</summary>
public enum IgpuMemoryPatch
{
    None,
    /// <summary>framebuffer-stolenmem 19 MB + framebuffer-fbmem 9 MB (Broadwell and newer).</summary>
    StolenFb,
    /// <summary>framebuffer-cursormem 9 MB (Haswell).</summary>
    HaswellCursor,
}

/// <summary>
/// One Intel iGPU family, keyed by an inclusive PCI device-id range. Carries both the OpenCore
/// framebuffer (little-endian ig-platform-id, optional device-id spoof, memory patch) and the
/// macOS support ceiling. <c>null</c> <see cref="PlatformId"/> means no known framebuffer, so the
/// installer boots that iGPU on the firmware (VESA) framebuffer instead.
/// </summary>
public sealed record IntelIgpu(
    int DeviceIdLow,
    int DeviceIdHigh,
    string Family,
    uint? PlatformId,
    uint? SpoofDeviceId,
    IgpuMemoryPatch MemoryPatch,
    int MaxSupportedDarwin,
    int MaxExperimentalDarwin,
    string Note);

/// <summary>
/// The single source of truth for Intel iGPU handling: framebuffer selection (Efi) and the version
/// tiles (Compatibility) both resolve against it, so the two can never drift. Values are taken from
/// the Dortania laptop iGPU guides. Ordered MOST-SPECIFIC FIRST — exact single-part entries precede
/// the generational ranges, and <see cref="Lookup"/> returns the first match.
/// </summary>
public static class IntelIgpuCatalog
{
    public static readonly IReadOnlyList<IntelIgpu> Entries = new IntelIgpu[]
    {
        // --- Exact parts that diverge from their generation's range (must come first) ---
        // Kaby Lake-R UHD 620 (e.g. i5-8350U, ThinkPad T480): own framebuffer, spoof to HD 620.
        new(0x5917, 0x5917, "Kaby Lake-R (UHD 620)", 0x87C00000, 0x5916, IgpuMemoryPatch.StolenFb, 22, 23,
            "Intel UHD 620 (Kaby Lake-R): maximal Ventura"),
        // Whiskey Lake UHD 620: uses the Comet-Lake framebuffer, spoof to UHD 630 (0x3E9B).
        new(0x3EA0, 0x3EA1, "Whiskey Lake (UHD 620)", 0x3E9B0000, 0x3E9B, IgpuMemoryPatch.StolenFb, 22, 23,
            "Intel UHD 620 (Whiskey Lake): maximal Ventura"),
        // Comet Lake-U UHD 620: spoof to UHD 630 (0x3E9B).
        new(0x9B41, 0x9B41, "Comet Lake (UHD 620)", 0x3E9B0000, 0x3E9B, IgpuMemoryPatch.StolenFb, 23, 24,
            "Intel UHD 620 (Comet Lake): maximal Sonoma"),

        // --- Generational ranges ---
        new(0x0100, 0x014F, "Sandy Bridge (HD 2000/3000)", null, null, IgpuMemoryPatch.None, 17, 17,
            "Intel HD 3000 (Sandy Bridge): maximal High Sierra, ohne Beschleunigung"),
        new(0x0150, 0x016F, "Ivy Bridge (HD 4000)", 0x01660003, null, IgpuMemoryPatch.None, 20, 20,
            "Intel HD 4000 (Ivy Bridge): maximal Big Sur"),
        new(0x0400, 0x0D3F, "Haswell (HD 4400/4600/5000)", 0x0A260006, 0x0412, IgpuMemoryPatch.HaswellCursor, 21, 21,
            "Intel HD 4400/4600/5000 (Haswell): maximal Monterey"),
        new(0x1600, 0x163F, "Broadwell (HD 5500/6000)", 0x16260006, 0x1626, IgpuMemoryPatch.StolenFb, 21, 21,
            "Intel HD 5500/6000 (Broadwell): maximal Monterey"),
        new(0x1900, 0x193F, "Skylake (HD 5xx)", 0x19160000, null, IgpuMemoryPatch.StolenFb, 21, 22,
            "Intel HD 5xx (Skylake): maximal Monterey"),
        new(0x5900, 0x593F, "Kaby Lake (HD/UHD 620/630)", 0x59160000, null, IgpuMemoryPatch.StolenFb, 22, 23,
            "Intel HD/UHD 620/630 (Kaby Lake): maximal Ventura"),
        new(0x3E00, 0x3EFF, "Coffee Lake (UHD 630)", 0x3EA50009, 0x3EA5, IgpuMemoryPatch.StolenFb, 22, 23,
            "Intel UHD 630 (Coffee Lake): maximal Ventura"),
        new(0x9B00, 0x9BFF, "Comet Lake (UHD 630)", 0x3EA50009, 0x3EA5, IgpuMemoryPatch.StolenFb, 23, 24,
            "Intel UHD 630 (Comet Lake): maximal Sonoma"),
        new(0x8A50, 0x8A7F, "Ice Lake (Iris Plus)", 0x8A520000, null, IgpuMemoryPatch.StolenFb, 23, 24,
            "Intel Iris Plus (Ice Lake): maximal Sonoma"),
    };

    /// <summary>The catalogued family for a PCI device-id, or <c>null</c> for an unrecognised Intel iGPU.</summary>
    public static IntelIgpu? Lookup(int deviceId) =>
        Entries.FirstOrDefault(e => deviceId >= e.DeviceIdLow && deviceId <= e.DeviceIdHigh);
}
