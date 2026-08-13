using System.Buffers.Binary;
using System.Security.Cryptography;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Download;

/// <summary>
/// Verifies a BaseSystem image against its Apple chunklist: each chunk record
/// carries a length and the SHA-256 of that many bytes read sequentially from
/// the image. Any mismatch, truncation or malformed chunklist is fatal.
/// </summary>
public static class ChunklistVerifier
{
    private const uint ChunklistMagic = 0x4C4B4E43; // 'CNKL'
    private const int HeaderSize = 36;
    private const int ChunkRecordSize = 36; // uint32 size + 32-byte sha256

    public static void Verify(string imagePath, string chunklistPath)
    {
        Log.Info("Prüfe Recovery-Abbildung gegen Chunklist.");

        var chunks = ReadChunks(chunklistPath);

        try
        {
            using var image = new FileStream(imagePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var sha256 = SHA256.Create();
            var buffer = new byte[1024 * 1024];

            foreach (var (chunkSize, expectedHash) in chunks)
            {
                var actualHash = HashChunk(image, sha256, buffer, chunkSize);
                if (!CryptographicOperations.FixedTimeEquals(actualHash, expectedHash))
                    throw Corrupt();
            }
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new SetupException(
                SetupStage.Verification,
                "Recovery-Abbildung konnte nicht gelesen werden.",
                "Download beschädigt – Setup erneut ausführen.",
                ex);
        }

        Log.Info($"Recovery-Abbildung verifiziert ({chunks.Count} Chunks).");
    }

    private static IReadOnlyList<(uint Size, byte[] Hash)> ReadChunks(string chunklistPath)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(chunklistPath);
        }
        catch (Exception ex)
        {
            throw new SetupException(
                SetupStage.Verification,
                "Chunklist konnte nicht gelesen werden.",
                "Download beschädigt – Setup erneut ausführen.",
                ex);
        }

        if (data.Length < HeaderSize)
            throw InvalidChunklist();

        var header = data.AsSpan();
        var magic = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (magic != ChunklistMagic)
            throw InvalidChunklist();

        // Header is packed <4sIBBBxQQQ: chunk_count@12, chunk_offset@20, signature_offset@28.
        var chunkCount = BinaryPrimitives.ReadUInt64LittleEndian(header.Slice(12, 8));
        var chunkOffset = BinaryPrimitives.ReadUInt64LittleEndian(header.Slice(20, 8));

        var end = chunkOffset + chunkCount * ChunkRecordSize;
        if (chunkOffset > (ulong)data.Length || end > (ulong)data.Length)
            throw InvalidChunklist();

        var chunks = new List<(uint, byte[])>((int)chunkCount);
        var cursor = (int)chunkOffset;
        for (ulong i = 0; i < chunkCount; i++)
        {
            var record = header.Slice(cursor, ChunkRecordSize);
            var size = BinaryPrimitives.ReadUInt32LittleEndian(record);
            var hash = record.Slice(4, 32).ToArray();
            chunks.Add((size, hash));
            cursor += ChunkRecordSize;
        }

        return chunks;
    }

    private static byte[] HashChunk(Stream image, SHA256 sha256, byte[] buffer, uint chunkSize)
    {
        sha256.Initialize();
        var remaining = chunkSize;
        while (remaining > 0)
        {
            var want = (int)Math.Min(remaining, (uint)buffer.Length);
            var read = image.Read(buffer, 0, want);
            if (read == 0)
                throw Corrupt(); // image shorter than the chunklist expects
            sha256.TransformBlock(buffer, 0, read, null, 0);
            remaining -= (uint)read;
        }

        sha256.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        return sha256.Hash!;
    }

    private static SetupException Corrupt() => new(
        SetupStage.Verification,
        "Prüfsumme der Recovery-Abbildung stimmt nicht.",
        "Download beschädigt – Setup erneut ausführen.");

    private static SetupException InvalidChunklist() => new(
        SetupStage.Verification,
        "Chunklist der Recovery-Abbildung ist ungültig.",
        "Download beschädigt – Setup erneut ausführen.");
}
