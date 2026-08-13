namespace MacOsUsbSetup.Core.Download;

/// <summary>
/// Byte progress for a single file. <see cref="TotalBytes"/> is null until the
/// server reports a content length.
/// </summary>
public sealed record DownloadProgress(string FileName, long BytesReceived, long? TotalBytes)
{
    public double? Fraction =>
        TotalBytes is > 0 ? Math.Clamp((double)BytesReceived / TotalBytes.Value, 0, 1) : null;
}
