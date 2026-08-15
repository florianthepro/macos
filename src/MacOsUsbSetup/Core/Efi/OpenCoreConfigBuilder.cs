using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Graphics;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.PropertyList;

namespace MacOsUsbSetup.Core.Efi;

/// <summary>
/// Produces an OpenCore config.plist as a plain object graph tailored to the
/// scanned hardware. The layout follows the OpenCore reference sample; only the
/// hardware-dependent parts (SMBIOS, AMD kernel patches, CPU quirks) vary.
/// </summary>
public sealed class OpenCoreConfigBuilder
{
    private static readonly Guid AppleBootGuid = new("7C436110-AB2A-4BBB-A880-FE41995C9F82");
    private static readonly Guid AppleGuiGuid  = new("4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14");

    private readonly EfiAssets _assets;

    public OpenCoreConfigBuilder(EfiAssets assets) => _assets = assets;

    public Dictionary<string, object?> Build(HardwareInventory hardware, MacOsRelease release)
    {
        var isAmd = hardware.Processor.Vendor == CpuVendor.Amd;
        var isLaptop = IsLaptop(hardware);
        var needsCurrentCpuInfo = isAmd || IsIntelHybrid(hardware.Processor);
        var (xcpmCfgLock, cpuPmCfgLock) = CfgLockQuirks(hardware.Processor);

        var kernel = BuildKernel(needsCurrentCpuInfo, xcpmCfgLock, cpuPmCfgLock);
        if (isAmd)
            ApplyAmdPatches(kernel, hardware);
        if (kernel["Add"] is object?[] baseKexts)
        {
            var kexts = baseKexts.AsEnumerable();
            if (isLaptop)
            {
                // Battery kexts (SMCBatteryManager/ECEnabler) are deliberately NOT baked in: they
                // are suspected of hanging boot mid-progress-bar on the reference T480. They stay
                // available as the optional post-install scripts/battery.command until verified.
                kexts = kexts.Concat(LaptopInputKexts())
                    .Append(Kext("AppleALC.kext", "Contents/MacOS/AppleALC"))                     // audio (with alcid boot-arg)
                    .Append(Kext("IntelBluetoothFirmware.kext", "Contents/MacOS/IntelBluetoothFirmware")) // Intel-BT (Lilu is a base kext)
                    .Append(Kext("IntelBTPatcher.kext", "Contents/MacOS/IntelBTPatcher"))
                    .Append(Kext("BlueToolFixup.kext", "Contents/MacOS/BlueToolFixup"));           // BT on macOS 12+ (-btlfxallowanyaddr set)
                // USB port map baked in for the T480 family (UHD 620 / Kaby-Lake-R, iGPU 0x5917):
                // internal camera/BT ports as connector type 255, so they enumerate from first boot.
                // The codeless USBMap.kext ships in the payload (see build.ps1). Other models: the
                // post-install scripts/usb-fix.command builds the map generically from the live system.
                var intelIgpu = hardware.GraphicsAdapters.FirstOrDefault(g => g.Vendor == GpuVendor.Intel);
                if (intelIgpu is not null && intelIgpu.PciDeviceId == 0x5917)
                    kexts = kexts.Append(Kext("USBMap.kext", "")); // codeless (empty ExecutablePath)
            }
            var wifi = WifiKext(release);
            if (wifi is not null)
                kexts = kexts.Append(wifi);
            kernel["Add"] = kexts.ToArray();
        }

        var (graphicsProperties, graphicsBootArgs) = BuildIntelGraphics(hardware, isLaptop);
        var bootArgs = BuildBootArgs(isLaptop, graphicsBootArgs);

        var config = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["ACPI"] = BuildAcpi(isLaptop),
            ["Booter"] = BuildBooter(isLaptop),
            ["DeviceProperties"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["Add"] = graphicsProperties,
                ["Delete"] = new Dictionary<string, object?>(),
            },
            ["Kernel"] = kernel,
            ["Misc"] = BuildMisc(isLaptop),
            ["NVRAM"] = BuildNvram(bootArgs),
            ["PlatformInfo"] = BuildPlatformInfo(hardware, release),
            ["UEFI"] = BuildUefi(),
        };
        if (isLaptop)
            Log.Info("Laptop erkannt: VoodooPS2 (Tastatur/Trackpad), SSDTs und iGPU-Framebuffer ergänzt.");
        return config;
    }

    private static Dictionary<string, object?> BuildAcpi(bool laptop) => new(StringComparer.Ordinal)
    {
        ["Add"] = laptop
            ? new object?[] { AcpiAdd("SSDT-EC-USBX-LAPTOP.aml"), AcpiAdd("SSDT-PLUG-DRTNIA.aml"), AcpiAdd("SSDT-PNLF.aml") }
            : Array.Empty<object?>(),
        ["Delete"] = Array.Empty<object?>(),
        ["Patch"] = Array.Empty<object?>(),
        ["Quirks"] = D(
            ("FadtEnableReset", false), ("NormalizeHeaders", false), ("RebaseRegions", false),
            ("ResetHwSig", false), ("ResetLogoStatus", true), ("SyncTableIds", false)),
    };

    private static Dictionary<string, object?> BuildBooter(bool laptop) => new(StringComparer.Ordinal)
    {
        ["MmioWhitelist"] = Array.Empty<object?>(),
        ["Patch"] = Array.Empty<object?>(),
        ["Quirks"] = D(
            ("AllowRelocationBlock", false), ("AvoidRuntimeDefrag", true), ("DevirtualiseMmio", false),
            ("DisableSingleUser", false), ("DisableVariableWrite", false), ("DiscardHibernateMap", false),
            // EnableWriteUnprotector removes the write protection on runtime code/data that stock
            // laptop firmware leaves set; without it the kernel faults writing a read-only page early
            // in boot ("No mapping exists for frame pointer"). Reference laptop configs enable it.
            ("EnableSafeModeSlide", true), ("EnableWriteUnprotector", laptop), ("ForceBooterSignature", false),
            ("ForceExitBootServices", false), ("ProtectMemoryRegions", false), ("ProtectSecureBoot", false),
            ("ProtectUefiServices", false), ("ProvideCustomSlide", true), ("ProvideMaxSlide", 0),
            // RebuildAppleMemoryMap=false is the modern default and the fix for a hang at
            // ExitBootServices; SetupVirtualMap + SyncRuntimePermissions cover the memory map.
            ("RebuildAppleMemoryMap", false), ("ResizeAppleGpuBars", -1), ("SetupVirtualMap", true),
            ("SignalAppleOS", false), ("SyncRuntimePermissions", true)),
    };

    private static Dictionary<string, object?> BuildKernel(
        bool provideCurrentCpuInfo, bool xcpmCfgLock, bool cpuPmCfgLock) => new(StringComparer.Ordinal)
    {
        ["Add"] = new object?[]
        {
            Kext("Lilu.kext", "Contents/MacOS/Lilu"),
            Kext("VirtualSMC.kext", "Contents/MacOS/VirtualSMC"),
            Kext("WhateverGreen.kext", "Contents/MacOS/WhateverGreen"),
            // Intel Ethernet: the reliable way to get the installer online (works in Recovery,
            // OSBundleRequired=Network-Root). Harmless when the machine has no Intel NIC.
            Kext("IntelMausi.kext", "Contents/MacOS/IntelMausi"),
        },
        ["Block"] = Array.Empty<object?>(),
        ["Emulate"] = D(
            ("Cpuid1Data", Array.Empty<byte>()), ("Cpuid1Mask", Array.Empty<byte>()),
            ("DummyPowerManagement", false), ("MaxKernel", ""), ("MinKernel", "")),
        ["Force"] = Array.Empty<object?>(),
        ["Patch"] = Array.Empty<object?>(),
        ["Quirks"] = D(
            ("AppleCpuPmCfgLock", cpuPmCfgLock), ("AppleXcpmCfgLock", xcpmCfgLock), ("AppleXcpmExtraMsrs", false),
            ("AppleXcpmForceBoost", false), ("CustomPciSerialDevice", false), ("CustomSMBIOSGuid", false),
            ("DisableIoMapper", true), ("DisableIoMapperMapping", false), ("DisableLinkeditJettison", true),
            ("DisableRtcChecksum", false), ("ExtendBTFeatureFlags", false), ("ExternalDiskIcons", false),
            ("ForceAquantiaEthernet", false), ("ForceSecureBootScheme", false), ("IncreasePciBarSize", false),
            ("LapicKernelPanic", false), ("LegacyCommpage", false), ("PanicNoKextDump", true),
            ("PowerTimeoutKernelPanic", true), ("ProvideCurrentCpuInfo", provideCurrentCpuInfo),
            ("SetApfsTrimTimeout", -1), ("ThirdPartyDrives", false), ("XhciPortLimit", false)),
        ["Scheme"] = D(
            ("CustomKernel", false), ("FuzzyMatch", true), ("KernelArch", "Auto"), ("KernelCache", "Auto")),
    };

    private static Dictionary<string, object?> BuildMisc(bool laptop) => new(StringComparer.Ordinal)
    {
        ["BlessOverride"] = Array.Empty<object?>(),
        ["Boot"] = D(
            ("ConsoleAttributes", 0), ("HibernateMode", "None"), ("HibernateSkipsPicker", false),
            // Short (not Full) registers a firmware boot entry that Insyde/Lenovo laptops tolerate,
            // helping the internal disk boot OpenCore standalone after install. Needs
            // RequestBootVarRouting=true (set). The \EFI\BOOT\BOOTx64.efi fallback remains the guarantee.
            ("HideAuxiliary", false), ("InstanceIdentifier", ""), ("LauncherOption", laptop ? "Short" : "Disabled"),
            ("LauncherPath", "Default"), ("PickerAttributes", 17), ("PickerAudioAssist", false),
            ("PickerMode", "Builtin"), ("PickerVariant", "Auto"), ("PollAppleHotKeys", true),
            ("ShowPicker", true), ("TakeoffDelay", 0), ("Timeout", 10)),
        ["Debug"] = D(
            ("AppleDebug", true), ("ApplePanic", true), ("DisableWatchDog", true), ("DisplayDelay", 0),
            // Target 67 also writes opencore-*.txt to the USB root for diagnostics.
            // Target 65 (0x41) = enable + log to file, WITHOUT the on-screen console spam (0x02).
            // opencore-*.txt is still written to the ESP for diagnostics.
            ("DisplayLevel", 2147483650L), ("LogModules", "*"), ("SysReport", false), ("Target", 65)),
        ["Entries"] = Array.Empty<object?>(),
        ["Security"] = D(
            ("AllowSetDefault", true), ("ApECID", 0), ("AuthRestart", false), ("BlacklistAppleUpdate", true),
            ("DmgLoading", "Signed"), ("EnablePassword", false), ("ExposeSensitiveData", 6),
            ("HaltLevel", 2147483648L), ("PasswordHash", Array.Empty<byte>()), ("PasswordSalt", Array.Empty<byte>()),
            ("ScanPolicy", 0), ("SecureBootModel", "Disabled"), ("Vault", "Optional")),
        ["Tools"] = Array.Empty<object?>(),
    };

    // Boot-args: clean by default; alcid enables AppleALC audio on laptops (11 is a common first
    // try, user-tweakable); -btlfxallowanyaddr lets BlueToolFixup accept the Intel Bluetooth
    // controller on Ventura+ even when it reports a NULL address (common on Intel laptop radios),
    // plus any graphics fallback such as -igfxvesa.
    private static string BuildBootArgs(bool laptop, string graphicsBootArgs)
    {
        var parts = new List<string>();
        if (laptop)
        {
            parts.Add("alcid=11");
            parts.Add("-btlfxallowanyaddr");
        }
        var graphics = graphicsBootArgs.Trim();
        if (graphics.Length > 0)
            parts.Add(graphics);
        return string.Join(" ", parts);
    }

    private static Dictionary<string, object?> BuildNvram(string bootArgs) => new(StringComparer.Ordinal)
    {
        ["Add"] = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            [AppleBootGuid.ToString().ToUpperInvariant()] = D(
                // Clean boot (Apple logo, no verbose text). Add "-v keepsyms=1 debug=0x100" to
                // diagnose a boot hang/panic.
                ("boot-args", bootArgs),
                ("csr-active-config", new byte[] { 0x00, 0x00, 0x00, 0x00 }),
                ("prev-lang:kbd", Encoding.ASCII.GetBytes("en-US:0")),
                ("run-efi-updater", "No")),
            [AppleGuiGuid.ToString().ToUpperInvariant()] = D(
                ("DefaultBackgroundColor", new byte[] { 0x00, 0x00, 0x00, 0x00 }),
                ("UIScale", new byte[] { 0x01 })),
        },
        ["Delete"] = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            [AppleBootGuid.ToString().ToUpperInvariant()] = new object?[] { "boot-args", "csr-active-config" },
            [AppleGuiGuid.ToString().ToUpperInvariant()] = new object?[] { "DefaultBackgroundColor", "UIScale" },
        },
        ["LegacySchema"] = new Dictionary<string, object?>(),
        ["WriteFlash"] = true,
    };

    private Dictionary<string, object?> BuildPlatformInfo(HardwareInventory hardware, MacOsRelease release)
    {
        var smbios = ChooseSmbios(hardware, release);
        Log.Info($"SMBIOS: {smbios} für macOS {release.Name}");

        var pair = _assets.MacserialFile is { } exe ? MacSerial.Generate(exe, smbios) : null;
        var serial = pair?.Serial ?? RandomAlphanumeric(12);
        var mlb = pair?.Mlb ?? RandomAlphanumeric(17);
        if (pair is null)
            Log.Warn("Seriennummer/MLB sind Platzhalter (macserial nicht verfügbar) - iMessage/FaceTime ggf. nicht möglich.");
        else
            Log.Info("Gültige SMBIOS-Seriennummer erzeugt (macserial) - für iMessage/FaceTime vorbereitet.");

        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["Automatic"] = true,
            ["CustomMemory"] = false,
            ["Generic"] = D(
                ("AdviseFeatures", false), ("MLB", mlb), ("MaxBIOSVersion", false),
                ("ProcessorType", 0), ("ROM", RandomBytes(6)), ("SpoofVendor", true),
                ("SystemMemoryStatus", "Auto"), ("SystemProductName", smbios),
                ("SystemSerialNumber", serial), ("SystemUUID", Guid.NewGuid().ToString().ToUpperInvariant())),
            ["UpdateDataHub"] = true,
            ["UpdateNVRAM"] = true,
            ["UpdateSMBIOS"] = true,
            ["UpdateSMBIOSMode"] = "Create",
            ["UseRawUuidEncoding"] = false,
        };
    }

    private static Dictionary<string, object?> BuildUefi() => new(StringComparer.Ordinal)
    {
        ["APFS"] = D(
            ("EnableJumpstart", true), ("GlobalConnect", false), ("HideVerbose", false),
            ("JumpstartHotPlug", false), ("MinDate", -1), ("MinVersion", -1)),
        ["AppleInput"] = D(
            ("AppleEvent", "Builtin"), ("CustomDelays", false), ("GraphicsInputMirroring", true),
            ("KeyInitialDelay", 50), ("KeySubsequentDelay", 5), ("PointerPollMask", -1),
            ("PointerPollMax", 0), ("PointerPollMin", 0), ("PointerSpeedDiv", 1), ("PointerSpeedMul", 1)),
        ["Audio"] = D(("AudioSupport", false)),
        ["ConnectDrivers"] = true,
        ["Drivers"] = new object?[]
        {
            Driver("OpenRuntime.efi"),
            Driver("HfsPlus.efi"),
        },
        ["Input"] = D(
            ("KeyFiltering", false), ("KeyForgetThreshold", 5), ("KeySupport", true),
            ("KeySupportMode", "Auto"), ("PointerSupport", false), ("PointerSupportMode", "ASUS"),
            ("TimerResolution", 50000)),
        ["Output"] = D(
            ("ClearScreenOnModeSwitch", false), ("ConsoleMode", ""), ("DirectGopRendering", false),
            ("ForceResolution", false), ("GopPassThrough", "Disabled"), ("IgnoreTextInGraphics", false),
            ("InitialMode", "Auto"), ("ProvideConsoleGop", true), ("ReconnectGraphicsOnConnect", false),
            ("ReconnectOnResChange", false), ("ReplaceTabWithSpace", false), ("Resolution", "Max"),
            ("SanitiseClearScreen", false), ("TextRenderer", "BuiltinGraphics"), ("UIScale", 0), ("UgaPassThrough", false)),
        ["ProtocolOverrides"] = D(
            ("AppleAudio", false), ("AppleBootPolicy", false), ("AppleDebugLog", false),
            ("AppleEg2Info", false), ("AppleFramebufferInfo", false), ("AppleImageConversion", false),
            ("AppleImg4Verification", false), ("AppleKeyMap", false), ("AppleRtcRam", false),
            ("AppleSecureBoot", false), ("AppleSmcIo", false), ("AppleUserInterfaceTheme", false),
            ("DataHub", false), ("DeviceProperties", false), ("FirmwareVolume", false),
            ("HashServices", false), ("OSInfo", false), ("UnicodeCollation", false)),
        ["Quirks"] = D(
            ("ActivateHpetSupport", false), ("DisableSecurityPolicy", false), ("EnableVectorAcceleration", true),
            ("EnableVmx", false), ("ExitBootServicesDelay", 0), ("ForceOcWriteFlash", false),
            ("ForgeUefiSupport", false), ("IgnoreInvalidFlexRatio", false), ("ReleaseUsbOwnership", true),
            ("ReloadOptionRoms", false), ("RequestBootVarRouting", true), ("ResizeGpuBars", -1),
            ("ResizeUsePciRbIo", false), ("ShimRetainProtocol", false), ("TscSyncTimeout", 0),
            ("UnblockFsConnect", false)),
        ["ReservedMemory"] = Array.Empty<object?>(),
    };

    private void ApplyAmdPatches(Dictionary<string, object?> kernel, HardwareInventory hardware)
    {
        var file = _assets.AmdPatchesFile;
        if (file is null)
        {
            Log.Warn("AMD-Kernel-Patches nicht im Payload gefunden - EFI wird ohne sie geschrieben.");
            return;
        }

        if (Plist.Read(File.ReadAllText(file)) is not IDictionary<string, object?> root ||
            root.TryGetValue("Kernel", out var kobj) is false || kobj is not IDictionary<string, object?> amdKernel)
        {
            Log.Warn("AMD-Patchdatei hat ein unerwartetes Format - übersprungen.");
            return;
        }

        if (amdKernel.TryGetValue("Patch", out var patchesObj) && patchesObj is IList<object?> patches)
        {
            var cores = (byte)Math.Clamp(hardware.Processor.PhysicalCores, 1, 254);
            foreach (var patch in patches.OfType<IDictionary<string, object?>>())
            {
                if (patch.TryGetValue("Comment", out var c) && c is string comment &&
                    comment.Contains("cpuid_cores_per_package", StringComparison.OrdinalIgnoreCase) &&
                    patch.TryGetValue("Replace", out var r) && r is byte[] replace && replace.Length >= 2)
                {
                    replace[1] = cores;
                }
            }
            kernel["Patch"] = patches;
            Log.Info($"AMD-Kernel-Patches eingefügt ({patches.Count} Einträge, {cores} Kerne).");
        }

        if (amdKernel.TryGetValue("Emulate", out var emu) && emu is IDictionary<string, object?> emulate)
            kernel["Emulate"] = emulate;
    }

    private static Dictionary<string, object?> Kext(string bundle, string executable) => D(
        ("Arch", "x86_64"), ("BundlePath", bundle), ("Comment", ""), ("Enabled", true),
        ("ExecutablePath", executable), ("MaxKernel", ""), ("MinKernel", ""), ("PlistPath", "Contents/Info.plist"));

    private static Dictionary<string, object?> Driver(string path) => D(
        ("Arguments", ""), ("Comment", ""), ("Enabled", true), ("LoadEarly", false), ("Path", path));

    private static Dictionary<string, object?> AcpiAdd(string path) => D(
        ("Comment", ""), ("Enabled", true), ("Path", path));

    // VoodooPS2 controller + plugins: laptop keyboard/trackpad (PS/2), essential to
    // navigate the installer without an external USB keyboard.
    private static IEnumerable<object?> LaptopInputKexts() => new object?[]
    {
        Kext("VoodooPS2Controller.kext", "Contents/MacOS/VoodooPS2Controller"),
        Kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext", "Contents/MacOS/VoodooInput"),
        Kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Keyboard.kext", "Contents/MacOS/VoodooPS2Keyboard"),
        Kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext", "Contents/MacOS/VoodooPS2Trackpad"),
        Kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext", "Contents/MacOS/VoodooPS2Mouse"),
    };

    // Native Intel Wi-Fi (AirportItlwm) for the *installed* system, matched to the target
    // macOS — the kext is compiled per release. Wi-Fi in the Recovery/installer itself is
    // unreliable (reverse-engineered against Apple's private Wi-Fi stack), so wired Ethernet
    // stays the recommended path for the install. Sequoia/Tahoe have no stable build yet.
    private static Dictionary<string, object?>? WifiKext(MacOsRelease release) => release.DarwinMajor switch
    {
        19 => Kext("AirportItlwm-Catalina.kext", "Contents/MacOS/AirportItlwm"),
        20 => Kext("AirportItlwm-BigSur.kext", "Contents/MacOS/AirportItlwm"),
        21 => Kext("AirportItlwm-Monterey.kext", "Contents/MacOS/AirportItlwm"),
        22 => Kext("AirportItlwm-Ventura.kext", "Contents/MacOS/AirportItlwm"),
        23 => Kext("AirportItlwm-Sonoma.kext", "Contents/MacOS/AirportItlwm"),
        _ => null,
    };

    // Intel iGPU framebuffer for the internal laptop display, resolved from the GPU's PCI
    // device-id against the shared IntelIgpuCatalog. The device-id is the reliable signal
    // (Kaby Lake and Kaby Lake-R share a CPU model but need different framebuffers). Returns
    // the DeviceProperties "Add" map plus any extra boot-arguments. An Intel iGPU with no
    // catalogued framebuffer falls back to the firmware (VESA) framebuffer so the installer
    // still shows a picture.
    private static (Dictionary<string, object?> Properties, string ExtraBootArgs) BuildIntelGraphics(
        HardwareInventory hardware, bool isLaptop)
    {
        var add = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (!isLaptop || hardware.Processor.Vendor != CpuVendor.Intel)
            return (add, "");

        var igpu = hardware.GraphicsAdapters.FirstOrDefault(g => g.Vendor == GpuVendor.Intel);
        if (igpu is null)
            return (add, "");

        var entry = IntelIgpuCatalog.Lookup(igpu.PciDeviceId);
        if (entry?.PlatformId is null)
        {
            Log.Info("Intel-iGPU ohne bekannten Framebuffer: VESA (unbeschleunigt) für eine sichere Anzeige.");
            return (add, " -igfxvesa");
        }

        var properties = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["AAPL,ig-platform-id"] = Le(entry.PlatformId.Value),
        };
        if (entry.SpoofDeviceId is not null)
            properties["device-id"] = Le(entry.SpoofDeviceId.Value);
        AddMemoryPatch(properties, entry.MemoryPatch);

        add["PciRoot(0x0)/Pci(0x2,0x0)"] = properties;
        Log.Info($"iGPU-Framebuffer: {entry.Family} (ig-platform-id 0x{entry.PlatformId.Value:X8}).");
        return (add, "");
    }

    // Framebuffer memory patch for firmware that locks DVMT-prealloc at 32 MB. The stolen/fb
    // values are harmless when more memory is available.
    private static void AddMemoryPatch(Dictionary<string, object?> props, IgpuMemoryPatch patch)
    {
        switch (patch)
        {
            case IgpuMemoryPatch.StolenFb:
                props["framebuffer-patch-enable"] = new byte[] { 0x01, 0x00, 0x00, 0x00 };
                props["framebuffer-stolenmem"] = new byte[] { 0x00, 0x00, 0x30, 0x01 };
                props["framebuffer-fbmem"] = new byte[] { 0x00, 0x00, 0x90, 0x00 };
                break;
            case IgpuMemoryPatch.HaswellCursor:
                props["framebuffer-patch-enable"] = new byte[] { 0x01, 0x00, 0x00, 0x00 };
                props["framebuffer-cursormem"] = new byte[] { 0x00, 0x00, 0x90, 0x00 };
                break;
        }
    }

    private static byte[] Le(uint value) => new[]
    {
        (byte)(value & 0xFF), (byte)((value >> 8) & 0xFF),
        (byte)((value >> 16) & 0xFF), (byte)((value >> 24) & 0xFF),
    };

    private static string ChooseSmbios(HardwareInventory hardware, MacOsRelease release)
    {
        if (hardware.Processor.Vendor == CpuVendor.Amd || !IsLaptop(hardware))
            return release.PreferredDesktopSmbios;

        // Laptop Intel: match a MacBookPro of the same CPU generation for power management.
        return hardware.Processor.Model switch
        {
            78 or 94 => "MacBookPro13,1",       // Skylake
            142 => "MacBookPro14,1",             // Kaby Lake (e.g. ThinkPad T480)
            158 => "MacBookPro15,2",             // Coffee Lake
            165 or 166 => "MacBookPro16,1",      // Comet Lake
            140 or 141 => "MacBookPro16,2",      // Ice / Tiger Lake
            _ => release.PreferredLaptopSmbios,
        };
    }

    private static bool IsLaptop(HardwareInventory hardware)
    {
        if (Regex.IsMatch(hardware.Processor.Brand, @"\d{3,5}\s*(U|H|HQ|HK|HX|HS|Y|MQ|M|G7)\b", RegexOptions.IgnoreCase))
            return true;
        var model = hardware.SystemModel.ToLowerInvariant();
        return model.Contains("laptop") || model.Contains("notebook");
    }

    private static bool IsIntelHybrid(ProcessorInfo cpu) =>
        cpu.Vendor == CpuVendor.Intel && cpu.Family == 6 && cpu.Model is 151 or 154 or 183;

    // CFG Lock (a locked MSR 0xE2) is enabled by default on most stock laptop firmware and
    // cannot be turned off there. macOS panics early when its power management writes that
    // MSR, so patch the write out. Haswell and newer use native XCPM (AppleXcpmCfgLock);
    // Sandy/Ivy Bridge and older use the legacy path (AppleCpuPmCfgLock). Harmless when the
    // firmware already leaves CFG Lock open.
    private static (bool XcpmCfgLock, bool CpuPmCfgLock) CfgLockQuirks(ProcessorInfo cpu)
    {
        if (cpu.Vendor != CpuVendor.Intel || cpu.Family != 6)
            return (false, false);
        var legacy = cpu.Model is 42 or 58 || (cpu.Model > 0 && cpu.Model <= 47);
        return legacy ? (false, true) : (true, false);
    }

    private static Dictionary<string, object?> D(params (string Key, object? Value)[] entries)
    {
        var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (key, value) in entries) dict[key] = value;
        return dict;
    }

    private static byte[] RandomBytes(int length) => RandomNumberGenerator.GetBytes(length);

    private static string RandomAlphanumeric(int length)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        var chars = new char[length];
        for (var i = 0; i < length; i++)
            chars[i] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
        return new string(chars);
    }
}
