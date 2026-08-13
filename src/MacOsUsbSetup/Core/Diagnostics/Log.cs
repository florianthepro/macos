using System.IO;
using System.Text;

namespace MacOsUsbSetup.Core.Diagnostics;

/// <summary>
/// Append-only session log. Everything the setup does is recorded to a file
/// next to the temp directory so a failed run can be inspected afterwards.
/// The interface subscribes to <see cref="LineWritten"/> to mirror progress.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private static readonly string LogFile = BuildLogPath();

    public static string FilePath => LogFile;

    public static event Action<string>? LineWritten;

    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);
    public static void Error(string message) => Write("ERROR", message);

    private static void Write(string level, string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss} {level,-5} {message}";
        lock (Gate)
        {
            try { File.AppendAllText(LogFile, line + Environment.NewLine, Encoding.UTF8); }
            catch { /* logging must never abort the setup */ }
        }
        LineWritten?.Invoke(line);
    }

    private static string BuildLogPath()
    {
        var dir = Path.Combine(Path.GetTempPath(), "MacOsUsbSetup");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, $"setup-{DateTime.Now:yyyyMMdd-HHmmss}.log");
    }
}
