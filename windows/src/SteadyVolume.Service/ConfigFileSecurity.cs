using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace SteadyVolume.Service;

/// <summary>
/// C:\ProgramData\SteadyVolume: owner SYSTEM, SYSTEM full control, Administrators read only,
/// nobody else. Inheritance from ProgramData is cut so the default "Users can create files" rule
/// does not apply.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class ConfigFileSecurity
{
    private static readonly SecurityIdentifier LocalSystem = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    public static void SecureDirectory(string directory)
    {
        Directory.CreateDirectory(directory);

        var security = new DirectorySecurity();
        security.SetOwner(LocalSystem);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(
            LocalSystem, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            Administrators, FileSystemRights.ReadAndExecute, inherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(directory).SetAccessControl(security);

        foreach (var file in Directory.EnumerateFiles(directory))
            SecureFile(file);
    }

    /// <summary>
    /// Makes SYSTEM the owner of the program folder and its files. The installer can't do this:
    /// an administrator may not assign ownership to another account without SeRestorePrivilege,
    /// but SYSTEM may take ownership for itself. The installer sets the DACL; this only sets the owner.
    /// </summary>
    public static void TakeOwnershipOfProgramFolder(string directory)
    {
        var dir = new DirectoryInfo(directory);
        var dirSecurity = dir.GetAccessControl(AccessControlSections.Owner);
        if (!LocalSystem.Equals(dirSecurity.GetOwner(typeof(SecurityIdentifier))))
        {
            dirSecurity.SetOwner(LocalSystem);
            dir.SetAccessControl(dirSecurity);
        }

        foreach (var file in dir.EnumerateFiles())
        {
            var fileSecurity = file.GetAccessControl(AccessControlSections.Owner);
            if (LocalSystem.Equals(fileSecurity.GetOwner(typeof(SecurityIdentifier))))
                continue;
            fileSecurity.SetOwner(LocalSystem);
            file.SetAccessControl(fileSecurity);
        }
    }

    public static void SecureFile(string path)
    {
        var security = new FileSecurity();
        security.SetOwner(LocalSystem);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(LocalSystem, FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(Administrators, FileSystemRights.Read, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
}
