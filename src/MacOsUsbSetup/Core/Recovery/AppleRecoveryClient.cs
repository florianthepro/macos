using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Diagnostics;
using MacOsUsbSetup.Core.Download;

namespace MacOsUsbSetup.Core.Recovery;

/// <summary>
/// Faithful reimplementation of OpenCore's macrecovery.py: negotiates a session
/// with osrecovery.apple.com, requests the signed BaseSystem download links for
/// a board id, and fetches plus verifies the image and its chunklist.
/// </summary>
public sealed class AppleRecoveryClient : IRecoveryImageService
{
    private const string BaseUrl = "http://osrecovery.apple.com";
    private const string RecoveryImageEndpoint = BaseUrl + "/InstallationPayload/RecoveryImage";
    private const string HostHeader = "osrecovery.apple.com";
    private const string UserAgent = "InternetRecovery/1.0";
    private const string MlbZero = "00000000000000000"; // 17 zeros, unknown serial

    private static readonly HttpClient LookupClient = CreateLookupClient();

    private readonly ResilientDownloader _downloader = new();

    private static HttpClient CreateLookupClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = true,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.None
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(60) };
    }

    public async Task<RecoveryImageInfo> ResolveAsync(MacOsRelease release, CancellationToken ct)
    {
        Log.Info($"Recovery-Links werden aufgelöst (Board {release.RecoveryBoardId}, {release.RecoveryOsType}).");

        var session = await OpenSessionAsync(ct);
        var fields = await RequestImageLinksAsync(release, session, ct);

        var info = new RecoveryImageInfo(
            release,
            ImageUrl: RequireField(fields, "AU"),
            ImageToken: RequireField(fields, "AT"),
            ImageDigest: RequireField(fields, "AH"),
            ChunklistUrl: RequireField(fields, "CU"),
            ChunklistToken: RequireField(fields, "CT"),
            ChunklistDigest: RequireField(fields, "CH"));

        Log.Info("Recovery-Links erfolgreich aufgelöst.");
        return info;
    }

    private static async Task<string> OpenSessionAsync(CancellationToken ct)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, BaseUrl + "/");
            ApplyCommonHeaders(request);

            using var response = await LookupClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);

            if (response.Headers.TryGetValues("Set-Cookie", out var cookies))
            {
                foreach (var cookie in cookies)
                {
                    var token = ExtractSessionToken(cookie);
                    if (token is not null)
                        return token;
                }
            }

            throw new SetupException(
                SetupStage.RecoveryLookup,
                "Der Apple-Wiederherstellungsdienst lieferte kein Sitzungscookie.",
                "Internetverbindung prüfen und Setup erneut ausführen.");
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new SetupException(
                SetupStage.RecoveryLookup,
                "Sitzung beim Apple-Wiederherstellungsdienst konnte nicht geöffnet werden.",
                "Internetverbindung prüfen und Setup erneut ausführen.",
                ex);
        }
    }

    private static async Task<IReadOnlyDictionary<string, string>> RequestImageLinksAsync(
        MacOsRelease release, string session, CancellationToken ct)
    {
        try
        {
            var body = string.Join('\n', new[]
            {
                $"cid={RandomHex(16)}",
                $"sn={MlbZero}",
                $"bid={release.RecoveryBoardId}",
                $"k={RandomHex(64)}",
                $"fg={RandomHex(64)}",
                $"os={release.RecoveryOsType}"
            });

            using var request = new HttpRequestMessage(HttpMethod.Post, RecoveryImageEndpoint);
            ApplyCommonHeaders(request);
            request.Headers.TryAddWithoutValidation("Cookie", session);
            request.Content = new StringContent(body, Encoding.ASCII);
            request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/plain");

            using var response = await LookupClient.SendAsync(request, HttpCompletionOption.ResponseContentRead, ct);

            if (!response.IsSuccessStatusCode)
                throw new SetupException(
                    SetupStage.RecoveryLookup,
                    $"Apple-Wiederherstellungsdienst lehnte die Anfrage ab (HTTP {(int)response.StatusCode}).",
                    "macOS-Auswahl und Internetverbindung prüfen, dann Setup erneut ausführen.");

            var text = await response.Content.ReadAsStringAsync(ct);
            return ParseKeyValueLines(text);
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new SetupException(
                SetupStage.RecoveryLookup,
                "Recovery-Links konnten nicht abgerufen werden.",
                "Internetverbindung prüfen und Setup erneut ausführen.",
                ex);
        }
    }

    public async Task DownloadAsync(
        RecoveryImageInfo info,
        string recoveryBootDirectory,
        IProgress<DownloadProgress> progress,
        CancellationToken ct)
    {
        try
        {
            Directory.CreateDirectory(recoveryBootDirectory);

            var imagePath = Path.Combine(recoveryBootDirectory, "BaseSystem.dmg");
            var chunklistPath = Path.Combine(recoveryBootDirectory, "BaseSystem.chunklist");

            Log.Info("Lade BaseSystem.dmg herunter.");
            await _downloader.DownloadAsync(
                info.ImageUrl,
                new Dictionary<string, string>
                {
                    ["Cookie"] = "AssetToken=" + info.ImageToken,
                    ["User-Agent"] = UserAgent
                },
                imagePath,
                "BaseSystem.dmg",
                progress,
                ct);

            Log.Info("Lade BaseSystem.chunklist herunter.");
            await _downloader.DownloadAsync(
                info.ChunklistUrl,
                new Dictionary<string, string>
                {
                    ["Cookie"] = "AssetToken=" + info.ChunklistToken,
                    ["User-Agent"] = UserAgent
                },
                chunklistPath,
                "BaseSystem.chunklist",
                progress,
                ct);

            ChunklistVerifier.Verify(imagePath, chunklistPath);
            Log.Info("Recovery-Download abgeschlossen und verifiziert.");
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new SetupException(
                SetupStage.RecoveryDownload,
                "Recovery-Abbildung konnte nicht heruntergeladen werden.",
                "Internetverbindung prüfen und Setup erneut ausführen.",
                ex);
        }
    }

    private static void ApplyCommonHeaders(HttpRequestMessage request)
    {
        request.Headers.TryAddWithoutValidation("Host", HostHeader);
        request.Headers.ConnectionClose = true;
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
    }

    private static string? ExtractSessionToken(string setCookie)
    {
        var start = setCookie.IndexOf("session=", StringComparison.Ordinal);
        if (start < 0)
            return null;

        var end = setCookie.IndexOf(';', start);
        return end < 0 ? setCookie[start..] : setCookie[start..end];
    }

    private static IReadOnlyDictionary<string, string> ParseKeyValueLines(string text)
    {
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            var separator = line.IndexOf(": ", StringComparison.Ordinal);
            if (separator <= 0)
                continue;

            var key = line[..separator];
            var value = line[(separator + 2)..].Trim();
            fields[key] = value;
        }

        return fields;
    }

    private static string RequireField(IReadOnlyDictionary<string, string> fields, string key)
    {
        if (fields.TryGetValue(key, out var value) && value.Length > 0)
            return value;

        throw new SetupException(
            SetupStage.RecoveryLookup,
            $"Antwort des Apple-Wiederherstellungsdienstes ist unvollständig (Feld {key} fehlt).",
            "macOS-Auswahl und Internetverbindung prüfen, dann Setup erneut ausführen.");
    }

    private static string RandomHex(int length)
    {
        var bytes = new byte[length / 2];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToHexString(bytes); // Convert.ToHexString yields uppercase
    }
}
