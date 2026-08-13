using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Graphics;
using MacOsUsbSetup.Core.Hardware;

using static MacOsUsbSetup.Core.Compatibility.CompatibilityLevel;

namespace MacOsUsbSetup.Core.Compatibility;

/// <summary>
/// Rates every catalogued macOS release against scanned hardware. Each release is
/// judged on two dimensions (CPU and GPU) resolved from raw PCI/CPUID facts; the
/// release verdict is the worse of the two, then adjusted for firmware and memory.
/// </summary>
public sealed class CompatibilityEvaluator : ICompatibilityEvaluator
{
    private const ulong TwoGigabytes = 2UL * 1024 * 1024 * 1024;
    private const ulong FourGigabytes = 4UL * 1024 * 1024 * 1024;

    private const int NvidiaMaxwellFirstDeviceId = 0x1340;

    public IReadOnlyList<CompatibilityResult> Evaluate(HardwareInventory hardware)
    {
        if (hardware is null)
            throw new SetupException(SetupStage.Compatibility,
                "Keine Hardware-Daten für die Bewertung übergeben.",
                "Hardware-Scan erneut ausführen.");

        try
        {
            var results = ReleaseCatalog.All
                .Select(release => EvaluateRelease(hardware, release))
                .ToList();

            var supported = results.Count(r => r.Level == Supported);
            var experimental = results.Count(r => r.Level == Experimental);
            Log.Info($"Kompatibilität bewertet: {supported} unterstützt, {experimental} experimentell, " +
                     $"{results.Count - supported - experimental} nicht unterstützt");

            return results;
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new SetupException(SetupStage.Compatibility,
                "Kompatibilitätsbewertung fehlgeschlagen.",
                "Logdatei prüfen und Hardware-Scan wiederholen.", ex);
        }
    }

    private static CompatibilityResult EvaluateRelease(HardwareInventory hw, MacOsRelease release)
    {
        var darwin = release.DarwinMajor;
        var notes = new List<string>();

        var cpu = EvaluateCpu(hw.Processor, darwin);
        if (cpu.Note is not null)
            notes.Add(cpu.Note);

        var gpu = EvaluateGpu(hw.GraphicsAdapters, darwin);
        notes.AddRange(gpu.Notes);

        var level = Worst(cpu.Level, gpu.Level);

        if (hw.Firmware == FirmwareMode.LegacyBios)
        {
            notes.Add("Legacy-BIOS erkannt: im UEFI-Modus booten (CSM deaktivieren)");
            if (level == Supported)
                level = Experimental;
        }

        if (hw.TotalMemoryBytes < TwoGigabytes)
        {
            notes.Add("Weniger als 2 GB RAM: für die Installation nicht ausreichend");
            level = Unsupported;
        }
        else if (hw.TotalMemoryBytes < FourGigabytes)
        {
            notes.Add("Weniger als 4 GB RAM: Installation kann langsam/instabil sein");
        }

        return new CompatibilityResult(release, level, notes);
    }

    // --- CPU dimension -----------------------------------------------------

    private static (CompatibilityLevel Level, string? Note) EvaluateCpu(ProcessorInfo cpu, int darwin) =>
        cpu.Vendor switch
        {
            CpuVendor.Intel => EvaluateIntelCpu(cpu, darwin),
            CpuVendor.Amd => cpu.Family >= 23
                ? ClassifyDim(darwin, 0, -1, 25,
                    "AMD-Ryzen: benötigt AMD-Vanilla-Kernel-Patches (im EFI enthalten); iMessage/FaceTime evtl. eingeschränkt", false)
                : ClassifyDim(darwin, 0, -1, -1, "AMD ohne Ryzen wird nicht unterstützt", false),
            _ => ClassifyDim(darwin, 0, -1, 25, "CPU-Hersteller unbekannt", false)
        };

    private static (CompatibilityLevel Level, string? Note) EvaluateIntelCpu(ProcessorInfo cpu, int darwin)
    {
        if (cpu.Family != 6)
            return ClassifyDim(darwin, 0, -1, 25, "Intel-CPU nicht klassifiziert", false);

        return cpu.Model switch
        {
            42 or 58 => ClassifyDim(darwin, 0, 21, 21, "Sandy/Ivy Bridge: maximal Monterey", false),
            <= 47 => ClassifyDim(darwin, 0, 18, 18, "alte Intel-CPU (maximal Mojave)", false),
            60 or 61 or 69 or 70 or 71 => ClassifyDim(darwin, 0, 24, 25, "Haswell/Broadwell: Tahoe nur experimentell", false),
            78 or 94 or 85 or 165 or 166 => ClassifyDim(darwin, 0, 25, 25, null, false),
            142 or 158 => ClassifyDim(darwin, 0, 25, 25, null, false),
            125 or 126 => ClassifyDim(darwin, 0, 25, 25, "Ice Lake: auf Desktop ggf. CPUFriend erforderlich", true),
            140 or 141 => ClassifyDim(darwin, 0, 25, 25, "Tiger Lake: auf Desktop ggf. CPUFriend erforderlich", true),
            151 or 154 or 183 => ClassifyDim(darwin, 0, -1, 25, "Hybrid-CPU: E-Cores ggf. deaktivieren", false),
            _ => ClassifyDim(darwin, 0, -1, 25, "Intel-CPU nicht klassifiziert", false)
        };
    }

    // --- GPU dimension -----------------------------------------------------

    private readonly record struct AdapterVerdict(
        GraphicsInfo Adapter, CompatibilityLevel Level, string? Note, bool ModernNvidia);

    private static (CompatibilityLevel Level, IReadOnlyList<string> Notes) EvaluateGpu(
        IReadOnlyList<GraphicsInfo> adapters, int darwin)
    {
        var notes = new List<string>();
        if (adapters.Count == 0)
        {
            notes.Add("Keine Grafikeinheit erkannt");
            return (Unsupported, notes);
        }

        var verdicts = adapters.Select(a => EvaluateAdapter(a, darwin)).ToList();

        // Most capable adapter is the ceiling; the others only add caveats.
        var best = verdicts.OrderBy(v => (int)v.Level).First();
        var level = best.Level;
        if (best.Note is not null)
            notes.Add(best.Note);

        if (verdicts.Any(v => v.ModernNvidia) && darwin >= 18)
        {
            const string nvidiaNote = "Nvidia: keine Treiber ab Mojave";
            if (!notes.Contains(nvidiaNote))
                notes.Add(nvidiaNote);

            if (level != Unsupported)
            {
                if (best.Adapter.Vendor == GpuVendor.Intel)
                {
                    level = Worst(Experimental, level);
                    notes.Add("nur iGPU headless nutzbar");
                }
                else
                {
                    notes.Add("Nvidia-GPU deaktivieren oder entfernen");
                }
            }
        }

        if (level == Unsupported && notes.Count == 0)
            notes.Add("Keine unterstützte Grafikeinheit für dieses Release");

        return (level, notes);
    }

    private static AdapterVerdict EvaluateAdapter(GraphicsInfo gpu, int darwin)
    {
        switch (gpu.Vendor)
        {
            case GpuVendor.Nvidia:
                if (IsModernNvidia(gpu))
                {
                    var level = darwin <= 17 ? Supported : Unsupported;
                    return new AdapterVerdict(gpu, level,
                        level == Supported ? null : "Nvidia: keine Treiber ab Mojave", true);
                }
                var kepler = ClassifyDim(darwin, 0, 20, 21, "Nvidia Kepler: maximal Big Sur", false);
                return new AdapterVerdict(gpu, kepler.Level, kepler.Note, false);

            case GpuVendor.Amd:
                var amd = EvaluateAmdGpu(gpu.PciDeviceId, darwin);
                return new AdapterVerdict(gpu, amd.Level, amd.Note, false);

            case GpuVendor.Intel:
                var intel = EvaluateIntelGpu(gpu.PciDeviceId, darwin);
                return new AdapterVerdict(gpu, intel.Level, intel.Note, false);

            default:
                return new AdapterVerdict(gpu, Experimental, "Grafik-Hersteller unbekannt", false);
        }
    }

    private static bool IsModernNvidia(GraphicsInfo gpu) => gpu.PciDeviceId >= NvidiaMaxwellFirstDeviceId;

    private static (CompatibilityLevel Level, string? Note) EvaluateAmdGpu(int deviceId, int darwin)
    {
        bool In(int lo, int hi) => deviceId >= lo && deviceId <= hi;

        // AMD APU integrated graphics (Raven Ridge/Picasso/Renoir/Cezanne/Rembrandt/Phoenix):
        // no macOS driver exists, so a Ryzen laptop with only its iGPU has no usable graphics.
        if (In(0x15D8, 0x15DF) || In(0x1636, 0x164F) || In(0x1680, 0x168F) || deviceId is 0x15BF or 0x15C8)
            return (Unsupported, "AMD-APU-Grafik (Vega/RDNA integriert): keine macOS-Treiber");
        if (In(0x7440, 0x745F))
            return (Unsupported, "AMD Navi3x (RX 7000): keine Treiber");
        if (In(0x73A0, 0x743F))
            return ClassifyDim(darwin, 21, 25, 25, "AMD Navi2x (RX 6000): ab Monterey", false);
        if (In(0x7310, 0x739F))
            return ClassifyDim(darwin, 19, 25, 25, "AMD Navi1x (RX 5000): ab Catalina", false);
        if (In(0x67C0, 0x67FF) || In(0x6980, 0x699F) || In(0x6860, 0x687F) || In(0x69A0, 0x69AF) || In(0x66A0, 0x66BF))
            return ClassifyDim(darwin, 16, 25, 25, null, false);

        return ClassifyDim(darwin, 0, 21, 21, "Alte AMD-GCN (HD 7000/R9 200): maximal Monterey", false);
    }

    private static (CompatibilityLevel Level, string? Note) EvaluateIntelGpu(int deviceId, int darwin)
    {
        // Same catalog the EFI builder uses for the framebuffer, so tiles and boot config agree.
        var entry = IntelIgpuCatalog.Lookup(deviceId);
        if (entry is null)
            return ClassifyDim(darwin, 0, -1, 25, "Intel-iGPU nicht klassifiziert - nur VESA (unbeschleunigt)", true);

        return ClassifyDim(darwin, 0, entry.MaxSupportedDarwin, entry.MaxExperimentalDarwin, entry.Note, false);
    }

    // --- shared classification --------------------------------------------

    /// <summary>
    /// Places <paramref name="darwin"/> on a support window: below <paramref name="minDarwin"/>
    /// the part is too new for the OS, up to <paramref name="maxSupported"/> it runs cleanly,
    /// up to <paramref name="maxExperimental"/> it boots with a caveat, above that it is blocked.
    /// </summary>
    private static (CompatibilityLevel Level, string? Note) ClassifyDim(
        int darwin, int minDarwin, int maxSupported, int maxExperimental, string? note, bool noteAlways)
    {
        var level =
            darwin < minDarwin ? Unsupported :
            darwin <= maxSupported ? Supported :
            darwin <= maxExperimental ? Experimental :
            Unsupported;

        var effectiveNote = noteAlways || level != Supported ? note : null;
        return (level, effectiveNote);
    }

    private static CompatibilityLevel Worst(CompatibilityLevel a, CompatibilityLevel b) =>
        (CompatibilityLevel)Math.Max((int)a, (int)b);
}
