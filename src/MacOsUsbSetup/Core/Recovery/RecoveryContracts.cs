using MacOsUsbSetup.Core.Compatibility;
using MacOsUsbSetup.Core.Download;

namespace MacOsUsbSetup.Core.Recovery;

/// <summary>
/// Signed download endpoints returned by the Apple recovery service for one
/// release: the BaseSystem image and its chunklist, each with a per-session
/// asset token and the service-reported digest.
/// </summary>
public sealed record RecoveryImageInfo(
    MacOsRelease Release,
    string ImageUrl,
    string ImageToken,
    string ImageDigest,
    string ChunklistUrl,
    string ChunklistToken,
    string ChunklistDigest);

public interface IRecoveryImageService
{
    /// <summary>Negotiates a session and resolves the signed download links.</summary>
    Task<RecoveryImageInfo> ResolveAsync(MacOsRelease release, CancellationToken ct);

    /// <summary>
    /// Downloads BaseSystem.dmg and BaseSystem.chunklist into
    /// <paramref name="recoveryBootDirectory"/> (com.apple.recovery.boot) and
    /// verifies the image against the chunklist before returning.
    /// </summary>
    Task DownloadAsync(
        RecoveryImageInfo info,
        string recoveryBootDirectory,
        IProgress<DownloadProgress> progress,
        CancellationToken ct);
}
