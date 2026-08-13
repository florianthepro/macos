using System.Net;
using System.Net.Http.Headers;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Download;

/// <summary>
/// Streams an HTTP resource to disk with resume and bounded retry. Transient
/// faults are retried with exponential backoff, each attempt resuming from the
/// bytes already on disk via a Range request; a definitive HTTP status is fatal.
/// </summary>
public sealed class ResilientDownloader
{
    private const int BufferSize = 1024 * 1024;
    private const int MaxAttempts = 5;

    private static readonly HttpClient SharedClient = CreateClient();

    private readonly HttpClient _client;

    public ResilientDownloader(HttpClient? client = null) => _client = client ?? SharedClient;

    private static HttpClient CreateClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = DecompressionMethods.None
        };
        return new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task DownloadAsync(
        string url,
        IReadOnlyDictionary<string, string> headers,
        string destinationPath,
        string displayName,
        IProgress<DownloadProgress> progress,
        CancellationToken ct)
    {
        for (var attempt = 1; ; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                await TransferAsync(url, headers, destinationPath, displayName, progress, ct);
                return;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex) when (attempt < MaxAttempts && IsTransient(ex))
            {
                var delay = TimeSpan.FromSeconds(Math.Pow(2, attempt));
                Log.Warn($"{displayName}: Übertragung fehlgeschlagen (Versuch {attempt}/{MaxAttempts}), erneuter Versuch in {delay.TotalSeconds:0}s: {ex.Message}");
                await Task.Delay(delay, ct);
            }
        }
    }

    private async Task TransferAsync(
        string url,
        IReadOnlyDictionary<string, string> headers,
        string destinationPath,
        string displayName,
        IProgress<DownloadProgress> progress,
        CancellationToken ct)
    {
        var existing = File.Exists(destinationPath) ? new FileInfo(destinationPath).Length : 0;

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        ApplyHeaders(request, headers);
        if (existing > 0)
            request.Headers.Range = new RangeHeaderValue(existing, null);

        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);

        if (!response.IsSuccessStatusCode)
            throw BuildStatusException(response.StatusCode, displayName);

        var append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
        var bytesReceived = append ? existing : 0;
        var contentLength = response.Content.Headers.ContentLength;
        var totalBytes = contentLength is null ? (long?)null : bytesReceived + contentLength.Value;

        var mode = append ? FileMode.Append : FileMode.Create;
        await using var file = new FileStream(destinationPath, mode, FileAccess.Write, FileShare.None, BufferSize);
        await using var source = await response.Content.ReadAsStreamAsync(ct);

        var buffer = new byte[BufferSize];
        var sinceReport = 0L;
        progress.Report(new DownloadProgress(displayName, bytesReceived, totalBytes));

        int read;
        while ((read = await source.ReadAsync(buffer, ct)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, read), ct);
            bytesReceived += read;
            sinceReport += read;
            if (sinceReport >= BufferSize)
            {
                progress.Report(new DownloadProgress(displayName, bytesReceived, totalBytes));
                sinceReport = 0;
            }
        }

        progress.Report(new DownloadProgress(displayName, bytesReceived, totalBytes));
    }

    private static void ApplyHeaders(HttpRequestMessage request, IReadOnlyDictionary<string, string> headers)
    {
        foreach (var (key, value) in headers)
            request.Headers.TryAddWithoutValidation(key, value);
    }

    private static bool IsTransient(Exception ex) => ex switch
    {
        HttpRequestException => true,
        IOException => true,
        TaskCanceledException => true, // caller's ct is filtered out by the surrounding when-clause
        _ => false
    };

    private static SetupException BuildStatusException(HttpStatusCode status, string displayName)
    {
        var code = (int)status;
        var remedy = code is 401 or 403
            ? "Sitzungstoken abgelaufen – Setup erneut ausführen."
            : "Verbindung und macOS-Auswahl prüfen, dann Setup erneut ausführen.";
        return new SetupException(
            SetupStage.RecoveryDownload,
            $"Download von {displayName} abgelehnt (HTTP {code}).",
            remedy);
    }
}
