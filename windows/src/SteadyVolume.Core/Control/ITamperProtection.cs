namespace SteadyVolume.Core.Control;

/// <summary>Platform hook for tightening and restoring the service's own permissions.</summary>
public interface ITamperProtection
{
    /// <summary>
    /// Returns the current, unprotected state so it can be restored later, or null if the
    /// current state is already the protected one (nothing worth saving).
    /// </summary>
    string? CaptureOriginal();

    /// <summary>Applies protection. Must be idempotent.</summary>
    void Protect();

    /// <summary>Restores <paramref name="original"/>, or the platform default when it is null.</summary>
    void Restore(string? original);
}

/// <summary>Used in development mode and on platforms where protection is done by the installer.</summary>
public sealed class NoTamperProtection : ITamperProtection
{
    public string? CaptureOriginal() => null;
    public void Protect() { }
    public void Restore(string? original) { }
}
