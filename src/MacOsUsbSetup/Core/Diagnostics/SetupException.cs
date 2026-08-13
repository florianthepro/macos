namespace MacOsUsbSetup.Core.Diagnostics;

/// <summary>
/// Carries a fault the user is meant to read: a plain technical message plus,
/// where one exists, a concrete remediation step. Thrown instead of letting a
/// raw framework exception surface to the interface.
/// </summary>
public sealed class SetupException : Exception
{
    public SetupStage Stage { get; }
    public string? Remedy { get; }

    public SetupException(SetupStage stage, string message, string? remedy = null, Exception? inner = null)
        : base(message, inner)
    {
        Stage = stage;
        Remedy = remedy;
    }
}
