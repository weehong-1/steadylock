using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using SteadyVolume.Core;
using SteadyVolume.Core.Ipc;
using SteadyVolume.Core.Platform.Windows;

namespace SteadyVolume.Cli;

internal sealed class ServiceUnavailableException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Talks to the service over the named pipe. Before sending anything it checks that the process
/// at the other end of the pipe is the running SteadyVolume service, so a process that grabbed the
/// pipe name first cannot collect passwords.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed partial class ServiceClient(string pipeName, bool verifyServer)
{
    private const int ConnectTimeoutMs = 5000;
    private static readonly TimeSpan ResponseTimeout = TimeSpan.FromSeconds(60);

    public async Task<IpcResponse> SendAsync(IpcRequest request)
    {
        using var pipe = new NamedPipeClientStream(
            ".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
        using var timeout = new CancellationTokenSource(ResponseTimeout);

        try
        {
            await pipe.ConnectAsync(ConnectTimeoutMs, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TimeoutException or IOException or UnauthorizedAccessException)
        {
            throw new ServiceUnavailableException("Could not connect to the SteadyVolume service.", ex);
        }

        if (verifyServer)
            VerifyServer(pipe);

        try
        {
            await IpcFraming.WriteAsync(pipe, request, timeout.Token).ConfigureAwait(false);
            return await IpcFraming.ReadAsync<IpcResponse>(pipe, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or IpcProtocolException or OperationCanceledException)
        {
            throw new ServiceUnavailableException("The connection to the service failed: " + ex.Message, ex);
        }
    }

    private static void VerifyServer(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var serverPid))
            throw new ServiceUnavailableException("Could not identify the process behind the control pipe.",
                new Win32Exception(Marshal.GetLastPInvokeError()));

        ServiceStatusSnapshot status;
        try
        {
            status = ServiceControlNative.QueryStatus(SteadyVolumeConstants.ServiceName);
        }
        catch (Win32Exception ex)
        {
            throw new ServiceUnavailableException("Could not query the SteadyVolume service.", ex);
        }

        if (status.State != ServiceRunState.Running || status.ProcessId != (int)serverPid)
            throw new ServiceUnavailableException(
                $"The control pipe is owned by process {serverPid}, which is not the SteadyVolume service. " +
                "Refusing to send anything. Another program may be impersonating the service.");
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeServerProcessId(SafeHandle pipe, out uint serverProcessId);
}
