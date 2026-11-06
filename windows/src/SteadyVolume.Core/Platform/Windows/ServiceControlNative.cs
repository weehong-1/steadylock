using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace SteadyVolume.Core.Platform.Windows;

public enum ServiceRunState
{
    NotInstalled,
    Stopped,
    StartPending,
    StopPending,
    Running,
    ContinuePending,
    PausePending,
    Paused,
    Unknown,
}

public readonly record struct ServiceStatusSnapshot(ServiceRunState State, int ProcessId);

/// <summary>Thin wrappers over the Service Control Manager API shared by the service and the CLI.</summary>
[SupportedOSPlatform("windows")]
public static partial class ServiceControlNative
{
    public const uint SC_MANAGER_CONNECT = 0x0001;
    public const uint SERVICE_QUERY_STATUS = 0x0004;
    public const uint READ_CONTROL = 0x0002_0000;
    public const uint WRITE_DAC = 0x0004_0000;
    public const uint DACL_SECURITY_INFORMATION = 0x0000_0004;
    private const int SC_STATUS_PROCESS_INFO = 0;
    private const int ERROR_SERVICE_DOES_NOT_EXIST = 1060;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;

    public static ServiceStatusSnapshot QueryStatus(string serviceName)
    {
        using var scm = OpenScm();
        var service = OpenServiceW(scm, serviceName, SERVICE_QUERY_STATUS);
        if (service.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            service.Dispose();
            if (error == ERROR_SERVICE_DOES_NOT_EXIST)
                return new ServiceStatusSnapshot(ServiceRunState.NotInstalled, 0);
            throw new Win32Exception(error, "Could not open the service.");
        }

        using (service)
        {
            // SERVICE_STATUS_PROCESS is 9 DWORDs.
            var buffer = new byte[36];
            if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, buffer, buffer.Length, out _))
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not query the service status.");

            var state = BitConverter.ToInt32(buffer, 4) switch
            {
                1 => ServiceRunState.Stopped,
                2 => ServiceRunState.StartPending,
                3 => ServiceRunState.StopPending,
                4 => ServiceRunState.Running,
                5 => ServiceRunState.ContinuePending,
                6 => ServiceRunState.PausePending,
                7 => ServiceRunState.Paused,
                _ => ServiceRunState.Unknown,
            };
            return new ServiceStatusSnapshot(state, BitConverter.ToInt32(buffer, 28));
        }
    }

    /// <summary>Returns the service DACL as a self-relative security descriptor.</summary>
    public static byte[] GetServiceSecurity(string serviceName)
    {
        using var scm = OpenScm();
        using var service = OpenServiceOrThrow(scm, serviceName, READ_CONTROL);
        QueryServiceObjectSecurity(service, DACL_SECURITY_INFORMATION, null, 0, out var needed);
        var error = Marshal.GetLastPInvokeError();
        if (needed <= 0 || error != ERROR_INSUFFICIENT_BUFFER)
            throw new Win32Exception(error, "Could not read the service security descriptor.");

        var buffer = new byte[needed];
        if (!QueryServiceObjectSecurity(service, DACL_SECURITY_INFORMATION, buffer, buffer.Length, out _))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not read the service security descriptor.");
        return buffer;
    }

    public static void SetServiceSecurity(string serviceName, byte[] selfRelativeDescriptor)
    {
        using var scm = OpenScm();
        using var service = OpenServiceOrThrow(scm, serviceName, READ_CONTROL | WRITE_DAC);
        if (!SetServiceObjectSecurity(service, DACL_SECURITY_INFORMATION, selfRelativeDescriptor))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not set the service security descriptor.");
    }

    private static ScHandle OpenScm()
    {
        var scm = OpenSCManagerW(null, null, SC_MANAGER_CONNECT);
        if (scm.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            scm.Dispose();
            throw new Win32Exception(error, "Could not connect to the Service Control Manager.");
        }

        return scm;
    }

    private static ScHandle OpenServiceOrThrow(ScHandle scm, string name, uint access)
    {
        var service = OpenServiceW(scm, name, access);
        if (service.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            service.Dispose();
            throw new Win32Exception(error, $"Could not open service '{name}'.");
        }

        return service;
    }

    public sealed class ScHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
    {
        public ScHandle() : base(ownsHandle: true) { }
        protected override bool ReleaseHandle() => CloseServiceHandle(handle);
    }

    [LibraryImport("advapi32.dll", EntryPoint = "OpenSCManagerW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial ScHandle OpenSCManagerW(string? machineName, string? databaseName, uint desiredAccess);

    [LibraryImport("advapi32.dll", EntryPoint = "OpenServiceW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial ScHandle OpenServiceW(ScHandle scm, string serviceName, uint desiredAccess);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseServiceHandle(IntPtr handle);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryServiceStatusEx(ScHandle service, int infoLevel, [Out] byte[] buffer, int bufferSize, out int bytesNeeded);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryServiceObjectSecurity(ScHandle service, uint securityInformation, [Out] byte[]? descriptor, int bufferSize, out int bytesNeeded);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetServiceObjectSecurity(ScHandle service, uint securityInformation, byte[] descriptor);
}
