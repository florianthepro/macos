using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Download;

namespace MacOsUsbSetup.Core.Recovery;

/// <summary>The full-installer package (InstallAssistant.pkg) download resolved for one release.</summary>
public sealed record InstallAssistantInfo(
    MacOsRelease Release, string Url, long SizeBytes, string Version, string Title);

public interface IInstallAssistantService
{
    /// <summary>Resolves the InstallAssistant.pkg download for a release (macOS 11 Big Sur and newer only).</summary>
    Task<InstallAssistantInfo> ResolveAsync(MacOsRelease release, CancellationToken ct);

    /// <summary>Streams InstallAssistant.pkg into <paramref name="dataDirectory"/> (resumable, ~12-18 GB).</summary>
    Task DownloadAsync(InstallAssistantInfo info, string dataDirectory, IProgress<DownloadProgress> progress, CancellationToken ct);
}

/// <summary>
/// Resolves and downloads Apple's full macOS installer for the offline USB. The download URL is
/// read out of Apple's public software-update catalog (never synthesised — the swcdn token
/// rotates), matching the catalog product whose version equals the chosen release. No Apple ID or
/// authentication is required. Only macOS 11+ ships a single InstallAssistant.pkg.
/// </summary>
public sealed class InstallAssistantClient : IInstallAssistantService
{
    // Apple merged catalog, Big Sur -> Tahoe. The newest catalog is a superset of the older ones.
    private const string CatalogUrl =
        "https://swscan.apple.com/content/catalogs/others/" +
        "index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-" +
        "mountainlion-lion-snowleopard-leopard.merged-1.sucatalog";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };
    private static readonly IReadOnlyDictionary<string, string> NoHeaders = new Dictionary<string, string>();
    private readonly ResilientDownloader _downloader = new();

    public async Task<InstallAssistantInfo> ResolveAsync(MacOsRelease release, CancellationToken ct)
    {
        if (release.DarwinMajor < 20)
            throw new InvalidOperationException(
                $"Ein Offline-Installer ist erst ab macOS Big Sur verfügbar, nicht für {release.Name}.");

        var targetMajor = release.MarketingVersion.Split('.')[0]; // "13" (Ventura), "11" (Big Sur)
        Log.Info($"Apple-Softwarekatalog wird gelesen (Offline-Installer {release.Name})…");
        var xml = await Http.GetStringAsync(CatalogUrl, ct).ConfigureAwait(false);
        var products = Value(XDocument.Parse(xml).Root!.Element("dict")!, "Products")
            ?? throw new InvalidOperationException("Softwarekatalog: Produktliste fehlt.");

        (string ver, DateTime date, string title, string url, long size)? best = null;
        var entries = products.Elements().ToList();
        for (var i = 0; i + 1 < entries.Count; i += 2)
        {
            if (entries[i].Name.LocalName != "key") continue;
            var product = entries[i + 1];

            var pkg = Value(product, "Packages")?.Elements("dict").FirstOrDefault(d =>
                (Value(d, "URL")?.Value ?? "").EndsWith("InstallAssistant.pkg", StringComparison.Ordinal));
            if (pkg is null) continue;

            var url = Value(pkg, "URL")!.Value;
            long.TryParse(Value(pkg, "Size")?.Value, out var size);

            var distUrl = Value(product, "Distributions") is { } dists ? Value(dists, "English")?.Value : null;
            var (ver, title) = distUrl is null ? ("", "") : await ReadDistAsync(distUrl, ct).ConfigureAwait(false);
            if (ver.Length == 0 || ver.Split('.')[0] != targetMajor) continue;

            DateTime.TryParse(Value(product, "PostDate")?.Value, out var date);
            if (best is null || date > best.Value.date)
                best = (ver, date, title, url, size);
        }

        if (best is null)
            throw new InvalidOperationException($"Kein Offline-Installer für {release.Name} im Apple-Katalog gefunden.");

        Log.Info($"Offline-Installer: {best.Value.title} {best.Value.ver} ({best.Value.size / 1_000_000_000d:0.#} GB).");
        return new InstallAssistantInfo(release, best.Value.url, best.Value.size, best.Value.ver, best.Value.title);
    }

    public Task DownloadAsync(InstallAssistantInfo info, string dataDirectory, IProgress<DownloadProgress> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(dataDirectory);
        var dest = Path.Combine(dataDirectory, "InstallAssistant.pkg");
        return _downloader.DownloadAsync(info.Url, NoHeaders, dest, "InstallAssistant.pkg", progress, ct);
    }

    private static async Task<(string Version, string Title)> ReadDistAsync(string distUrl, CancellationToken ct)
    {
        try
        {
            var dist = await Http.GetStringAsync(distUrl, ct).ConfigureAwait(false);
            var ver = Regex.Match(dist, "id=\"InstallAssistantAuto\"[^>]*versStr=\"([^\"]+)\"");
            var title = Regex.Match(dist, "<title>(.+?)</title>");
            return (ver.Success ? ver.Groups[1].Value : "", title.Success ? title.Groups[1].Value : "");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return ("", ""); // a product whose .dist is unreadable is simply skipped
        }
    }

    // Apple's XML plist stores dictionaries as alternating <key>/<value> siblings; return the
    // value element that follows the given key inside a <dict>.
    private static XElement? Value(XElement dict, string key)
    {
        var kids = dict.Elements().ToList();
        for (var i = 0; i + 1 < kids.Count; i++)
            if (kids[i].Name.LocalName == "key" && kids[i].Value == key)
                return kids[i + 1];
        return null;
    }
}
