namespace MacOsUsbSetup.Core.Compatibility;

/// <summary>
/// The macOS releases this setup can build an installer for. Board identifiers
/// map one release to a Mac model the Apple recovery service still serves it to;
/// they are drawn from OpenCore's macrecovery board list.
/// </summary>
public static class ReleaseCatalog
{
    public static IReadOnlyList<MacOsRelease> All { get; } = new[]
    {
        new MacOsRelease("Tahoe",       "26", "latest", 25, 90,
            "Mac-27AD2F918AE68F61", "latest",  "MacPro7,1",  "MacBookPro16,1"),
        new MacOsRelease("Sequoia",     "15", "15.7.4", 24, 80,
            "Mac-0CFF9C7C2B63DF8D", "default", "MacPro7,1",  "MacBookPro16,1"),
        new MacOsRelease("Sonoma",      "14", "14.8.4", 23, 70,
            "Mac-827FAC58A8FDFA22", "default", "MacPro7,1",  "MacBookPro16,1"),
        new MacOsRelease("Ventura",     "13", "13.7.8", 22, 60,
            "Mac-EE2EBD4B90B839A8", "default", "iMacPro1,1", "MacBookPro16,1"),
        new MacOsRelease("Monterey",    "12", "12.7.6", 21, 50,
            "Mac-9AE82516C7C6B903", "default", "iMacPro1,1", "MacBookPro15,1"),
        new MacOsRelease("Big Sur",     "11", "11.7.11", 20, 40,
            "Mac-BE0E8AC46FE800CC", "default", "iMacPro1,1", "MacBookPro15,1"),
        new MacOsRelease("Catalina",    "10.15", "10.15.8", 19, 30,
            "Mac-66F35F19FE2A0D05", "default", "iMacPro1,1", "MacBookPro14,1"),
        new MacOsRelease("High Sierra", "10.13", "10.13.6", 17, 20,
            "Mac-942452F5819B1C1B", "default", "iMac14,2",   "MacBookPro11,1"),
    };

    public static MacOsRelease? ByDarwinMajor(int darwinMajor) =>
        All.FirstOrDefault(r => r.DarwinMajor == darwinMajor);
}
