using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
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
        var needsCurrentCpuInfo = isAmd || IsIntelHybrid(hardware.Processor);

        var kernel = BuildKernel(needsCurrentCpuInfo);
        if (isAmd)
            ApplyAmdPatches(kernel, hardware);

        var config = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["ACPI"] = BuildAcpi(),
            ["Booter"] = BuildBooter(),
            ["DeviceProperties"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["Add"] = new Dictionary<string, object?>(),
                ["Delete"] = new Dictionary<string, object?>(),
            },
            ["Kernel"] = kernel,
            ["Misc"] = BuildMisc(),
            ["NVRAM"] = BuildNvram(),
            ["PlatformInfo"] = BuildPlatformInfo(hardware, release),
            ["UEFI"] = BuildUefi(),
        };
        return config;
    }

    private static Dictionary<string, object?> BuildAcpi() => new(StringComparer.Ordinal)
    {
        ["Add"] = Array.Empty<object?>(),
        ["Delete"] = Array.Empty<object?>(),
        ["Patch"] = Array.Empty<object?>(),
        ["Quirks"] = D(
            ("FadtEnableReset", false), ("NormalizeHeaders", false), ("RebaseRegions", false),
            ("ResetHwSig", false), ("ResetLogoStatus", true), ("SyncTableIds", false)),
    };

    private static Dictionary<string, object?> BuildBooter() => new(StringComparer.Ordinal)
    {
        ["MmioWhitelist"] = Array.Empty<object?>(),
        ["Patch"] = Array.Empty<object?>(),
        ["Quirks"] = D(
            ("AllowRelocationBlock", false), ("AvoidRuntimeDefrag", true), ("DevirtualiseMmio", false),
            ("DisableSingleUser", false), ("DisableVariableWrite", false), ("DiscardHibernateMap", false),
            ("EnableSafeModeSlide", true), ("EnableWriteUnprotector", false), ("ForceBooterSignature", false),
            ("ForceExitBootServices", false), ("ProtectMemoryRegions", false), ("ProtectSecureBoot", false),
            ("ProtectUefiServices", false), ("ProvideCustomSlide", true), ("ProvideMaxSlide", 0),
            ("RebuildAppleMemoryMap", true), ("ResizeAppleGpuBars", -1), ("SetupVirtualMap", true),
            ("SignalAppleOS", false), ("SyncRuntimePermissions", true)),
    };

    private static Dictionary<string, object?> BuildKernel(bool provideCurrentCpuInfo) => new(StringComparer.Ordinal)
    {
        ["Add"] = new object?[]
        {
            Kext("Lilu.kext", "Contents/MacOS/Lilu"),
            Kext("VirtualSMC.kext", "Contents/MacOS/VirtualSMC"),
            Kext("WhateverGreen.kext", "Contents/MacOS/WhateverGreen"),
        },
        ["Block"] = Array.Empty<object?>(),
        ["Emulate"] = D(
            ("Cpuid1Data", Array.Empty<byte>()), ("Cpuid1Mask", Array.Empty<byte>()),
            ("DummyPowerManagement", false), ("MaxKernel", ""), ("MinKernel", "")),
        ["Force"] = Array.Empty<object?>(),
        ["Patch"] = Array.Empty<object?>(),
        ["Quirks"] = D(
            ("AppleCpuPmCfgLock", false), ("AppleXcpmCfgLock", false), ("AppleXcpmExtraMsrs", false),
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

    private static Dictionary<string, object?> BuildMisc() => new(StringComparer.Ordinal)
    {
        ["BlessOverride"] = Array.Empty<object?>(),
        ["Boot"] = D(
            ("ConsoleAttributes", 0), ("HibernateMode", "None"), ("HibernateSkipsPicker", false),
            ("HideAuxiliary", false), ("InstanceIdentifier", ""), ("LauncherOption", "Disabled"),
            ("LauncherPath", "Default"), ("PickerAttributes", 17), ("PickerAudioAssist", false),
            ("PickerMode", "Builtin"), ("PickerVariant", "Auto"), ("PollAppleHotKeys", true),
            ("ShowPicker", true), ("TakeoffDelay", 0), ("Timeout", 10)),
        ["Debug"] = D(
            ("AppleDebug", true), ("ApplePanic", true), ("DisableWatchDog", true), ("DisplayDelay", 0),
            ("DisplayLevel", 2147483650L), ("LogModules", "*"), ("SysReport", false), ("Target", 3)),
        ["Entries"] = Array.Empty<object?>(),
        ["Security"] = D(
            ("AllowSetDefault", true), ("ApECID", 0), ("AuthRestart", false), ("BlacklistAppleUpdate", true),
            ("DmgLoading", "Signed"), ("EnablePassword", false), ("ExposeSensitiveData", 6),
            ("HaltLevel", 2147483648L), ("PasswordHash", Array.Empty<byte>()), ("PasswordSalt", Array.Empty<byte>()),
            ("ScanPolicy", 0), ("SecureBootModel", "Disabled"), ("Vault", "Optional")),
        ["Tools"] = Array.Empty<object?>(),
    };

    private static Dictionary<string, object?> BuildNvram() => new(StringComparer.Ordinal)
    {
        ["Add"] = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            [AppleBootGuid.ToString().ToUpperInvariant()] = D(
                ("boot-args", "-v keepsyms=1 debug=0x100"),
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
        ["LegacyEnable"] = false,
        ["LegacySchema"] = new Dictionary<string, object?>(),
        ["WriteFlash"] = true,
    };

    private Dictionary<string, object?> BuildPlatformInfo(HardwareInventory hardware, MacOsRelease release)
    {
        var smbios = ChooseSmbios(hardware, release);
        Log.Info($"SMBIOS: {smbios} für macOS {release.Name}");
        Log.Warn("Seriennummer/MLB sind Platzhalter – für iMessage/FaceTime später gültige Werte generieren.");

        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["Automatic"] = true,
            ["CustomMemory"] = false,
            ["Generic"] = D(
                ("AdviseFeatures", false), ("MLB", RandomAlphanumeric(17)), ("MaxBIOSVersion", false),
                ("ProcessorType", 0), ("ROM", RandomBytes(6)), ("SpoofVendor", true),
                ("SystemMemoryStatus", "Auto"), ("SystemProductName", smbios),
                ("SystemSerialNumber", RandomAlphanumeric(12)), ("SystemUUID", Guid.NewGuid().ToString().ToUpperInvariant())),
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
            Log.Warn("AMD-Kernel-Patches nicht im Payload gefunden – EFI wird ohne sie geschrieben.");
            return;
        }

        if (Plist.Read(File.ReadAllText(file)) is not IDictionary<string, object?> root ||
            root.TryGetValue("Kernel", out var kobj) is false || kobj is not IDictionary<string, object?> amdKernel)
        {
            Log.Warn("AMD-Patchdatei hat ein unerwartetes Format – übersprungen.");
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

    private static string ChooseSmbios(HardwareInventory hardware, MacOsRelease release) =>
        hardware.Processor.Vendor == CpuVendor.Amd
            ? release.PreferredDesktopSmbios
            : IsLaptop(hardware) ? release.PreferredLaptopSmbios : release.PreferredDesktopSmbios;

    private static bool IsLaptop(HardwareInventory hardware)
    {
        if (Regex.IsMatch(hardware.Processor.Brand, @"\d{3,5}\s*(U|H|HQ|HK|HX|HS|Y|MQ|M|G7)\b", RegexOptions.IgnoreCase))
            return true;
        var model = hardware.SystemModel.ToLowerInvariant();
        return model.Contains("laptop") || model.Contains("notebook");
    }

    private static bool IsIntelHybrid(ProcessorInfo cpu) =>
        cpu.Vendor == CpuVendor.Intel && cpu.Family == 6 && cpu.Model is 151 or 154 or 183;

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
