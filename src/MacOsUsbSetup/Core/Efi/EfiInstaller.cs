using System.IO;
using System.Text;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Hardware;
using MacOsUsbSetup.Core.PropertyList;
using MacOsUsbSetup.Core.Usb;

namespace MacOsUsbSetup.Core.Efi;

/// <summary>
/// Copies the bundled EFI tree onto the prepared volume and writes a
/// hardware-specific config.plist next to OpenCore.
/// </summary>
public sealed class EfiInstaller : IEfiInstaller
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly EfiAssets _assets;
    private readonly OpenCoreConfigBuilder _configBuilder;

    public EfiInstaller(EfiAssets assets, OpenCoreConfigBuilder configBuilder)
    {
        _assets = assets;
        _configBuilder = configBuilder;
    }

    public async Task InstallAsync(
        PreparedVolume volume,
        HardwareInventory hardware,
        MacOsRelease release,
        IProgress<string> log,
        CancellationToken ct)
    {
        try
        {
            var source = _assets.EfiTemplateDirectory;
            var target = Path.Combine(volume.RootPath, "EFI");
            log.Report("EFI-Vorlage wird auf den USB kopiert");
            await Task.Run(() => CopyDirectory(source, target, ct), ct);

            log.Report("config.plist wird für die erkannte Hardware erzeugt");
            var config = _configBuilder.Build(hardware, release);
            var configPath = Path.Combine(target, "OC", "config.plist");
            await File.WriteAllTextAsync(configPath, Plist.Write(config), Utf8NoBom, ct);
            log.Report("EFI vollständig geschrieben");
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new SetupException(SetupStage.EfiInstallation,
                "Der EFI-Ordner konnte nicht geschrieben werden.",
                "USB-Datenträger prüfen (Schreibschutz/Platz) und Setup erneut ausführen.", ex);
        }
    }

    private static void CopyDirectory(string source, string target, CancellationToken ct)
    {
        Directory.CreateDirectory(target);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
        {
            ct.ThrowIfCancellationRequested();
            Directory.CreateDirectory(directory.Replace(source, target));
        }
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            ct.ThrowIfCancellationRequested();
            File.Copy(file, file.Replace(source, target), overwrite: true);
        }
    }
}
