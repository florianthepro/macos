using System.IO;
using System.IO.Compression;
using System.Reflection;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Efi;

/// <summary>
/// Extracts the EFI payload embedded at build time (OpenCore, drivers, kexts)
/// into a temp directory that the installer copies onto the USB. The payload is
/// produced by build.ps1 from upstream releases and never shipped in source.
/// </summary>
public sealed class EfiAssets
{
    private const string ResourceName = "efi-payload.zip";
    private readonly Lazy<string> _root = new(Extract);

    public static bool IsBundled =>
        Assembly.GetExecutingAssembly().GetManifestResourceNames()
            .Any(n => n.EndsWith(ResourceName, StringComparison.OrdinalIgnoreCase));

    /// <summary>Directory containing the extracted <c>EFI/</c> template tree.</summary>
    public string EfiTemplateDirectory => Path.Combine(_root.Value, "EFI");

    /// <summary>Extraction root holding the EFI tree plus side files (amd-patches.plist, payload.json).</summary>
    public string PayloadDirectory => _root.Value;

    /// <summary>AMD Vanilla kernel patches injected for AMD processors; null when absent.</summary>
    public string? AmdPatchesFile
    {
        get
        {
            var path = Path.Combine(_root.Value, "amd-patches.plist");
            return File.Exists(path) ? path : null;
        }
    }

    /// <summary>Bundled macserial.exe (OpenCorePkg) for valid iMessage-capable serials; null when absent.</summary>
    public string? MacserialFile
    {
        get
        {
            var path = Path.Combine(_root.Value, "macserial.exe");
            return File.Exists(path) ? path : null;
        }
    }

    private static string Extract()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resource = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(ResourceName, StringComparison.OrdinalIgnoreCase));
        if (resource is null)
            throw new SetupException(SetupStage.EfiInstallation,
                "Die EFI-Nutzdaten fehlen im Programm.",
                "Die setup.exe wurde ohne EFI-Payload gebaut. build.ps1 erneut ausführen.");

        var target = Path.Combine(Path.GetTempPath(), "MacOsUsbSetup", "efi-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(target);

        using var stream = assembly.GetManifestResourceStream(resource)!;
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
        archive.ExtractToDirectory(target, overwriteFiles: true);

        if (!Directory.Exists(Path.Combine(target, "EFI")))
            throw new SetupException(SetupStage.EfiInstallation,
                "Die EFI-Nutzdaten sind unvollständig.",
                "efi-payload.zip enthält keinen EFI-Ordner. build.ps1 erneut ausführen.");

        Log.Info($"EFI-Payload entpackt nach {target}");
        return target;
    }
}
