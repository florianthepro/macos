using System.Diagnostics;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.Core.Efi;

/// <summary>
/// Runs the bundled macserial (from OpenCorePkg) to produce a valid, model-correct SMBIOS
/// serial and board serial (MLB). Random placeholders make iMessage/FaceTime fail; a serial in
/// the model's real format is the prerequisite for Apple services to activate.
/// </summary>
internal static class MacSerial
{
    public static (string Serial, string Mlb)? Generate(string exePath, string model)
    {
        try
        {
            var psi = new ProcessStartInfo(exePath)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-m");
            psi.ArgumentList.Add(model);
            psi.ArgumentList.Add("--num");
            psi.ArgumentList.Add("1");

            using var process = Process.Start(psi);
            if (process is null)
                return null;
            var output = process.StandardOutput.ReadToEnd();
            if (!process.WaitForExit(10000))
            {
                try { process.Kill(); } catch { /* best effort */ }
                return null;
            }

            // macserial prints one "SERIAL | MLB" pair per line (warnings go to stderr).
            foreach (var line in output.Split('\n'))
            {
                var parts = line.Split('|');
                if (parts.Length != 2)
                    continue;
                var serial = parts[0].Trim();
                var mlb = parts[1].Trim();
                if (serial.Length is >= 11 and <= 12 && mlb.Length is >= 13 and <= 17)
                    return (serial, mlb);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"macserial konnte nicht ausgeführt werden: {ex.Message}");
        }
        return null;
    }
}
