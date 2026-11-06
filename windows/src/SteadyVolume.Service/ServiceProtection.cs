using System.Runtime.Versioning;
using System.Security.AccessControl;
using SteadyVolume.Core.Control;
using SteadyVolume.Core.Platform.Windows;

namespace SteadyVolume.Service;

/// <summary>
/// Tightens the service's own DACL so only SYSTEM can stop, pause, reconfigure or delete it.
/// Administrators keep query and start rights.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class ServiceProtection : ITamperProtection
{
    // Rights: CC query config, LC query status, SW enum dependents, RP start, WP stop, DT pause/continue,
    // LO interrogate, CR user-defined control, SD delete, RC read control, WD write DAC, WO write owner.
    // DC change config.

    /// <summary>
    /// The DACL install.ps1 sets with "sc.exe sdset". Same as the Windows default, plus full control
    /// for SYSTEM so the service can later tighten its own DACL. Restored on unprotect when no
    /// original was captured.
    /// </summary>
    public const string DefaultDacl =
        "D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)";

    /// <summary>Protected DACL: SYSTEM full control; Administrators query and start only; users query only.</summary>
    public const string ProtectedDacl =
        "D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCLCSWRPLOCRRC;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;CCLCSWLOCRRC;;;AU)";

    private readonly string _serviceName;

    public ServiceProtection(string serviceName) => _serviceName = serviceName;

    public string? CaptureOriginal()
    {
        var current = ReadDacl();
        return current == Normalize(ProtectedDacl) ? null : current;
    }

    public void Protect() => WriteDacl(ProtectedDacl);

    public void Restore(string? original)
    {
        var target = DefaultDacl;
        if (!string.IsNullOrWhiteSpace(original))
        {
            try
            {
                _ = new RawSecurityDescriptor(original);
                target = original;
            }
            catch (ArgumentException)
            {
                // Corrupt saved value: fall back to the known default rather than failing the unprotect.
            }
        }

        WriteDacl(target);
    }

    private string ReadDacl()
    {
        var bytes = ServiceControlNative.GetServiceSecurity(_serviceName);
        return new RawSecurityDescriptor(bytes, 0).GetSddlForm(AccessControlSections.Access);
    }

    private void WriteDacl(string sddl)
    {
        var descriptor = new RawSecurityDescriptor(sddl);
        var bytes = new byte[descriptor.BinaryLength];
        descriptor.GetBinaryForm(bytes, 0);
        ServiceControlNative.SetServiceSecurity(_serviceName, bytes);
    }

    private static string Normalize(string sddl) =>
        new RawSecurityDescriptor(sddl).GetSddlForm(AccessControlSections.Access);
}
