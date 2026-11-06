using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using SteadyVolume.Core.Control;
using SteadyVolume.Core.Ipc;

namespace SteadyVolume.Service;

/// <summary>
/// Named pipe control channel. Any authenticated local user may connect; network logons are
/// denied. Only SYSTEM can create further instances of the pipe. The password, checked inside the
/// service, is what protects the commands.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class PipeServer(
    CommandProcessor processor,
    ServiceOptions options,
    TimeProvider time,
    ILogger<PipeServer> logger) : BackgroundService
{
    private const int MaxConcurrentClients = 4;
    private static readonly TimeSpan ClientTimeout = TimeSpan.FromSeconds(30);

    private readonly RevertLogThrottle _errorLog = new(time, TimeSpan.FromMinutes(1));
    private readonly object _errorLogGate = new();

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var security = BuildSecurity(options.DevMode);
        using var slots = new SemaphoreSlim(MaxConcurrentClients);
        var firstInstance = true;

        while (!stoppingToken.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                await slots.WaitAsync(stoppingToken).ConfigureAwait(false);
                // The first instance is created with FirstPipeInstance so that if another process
                // already owns the name (pipe squatting) we fail loudly instead of sharing it.
                server = NamedPipeServerStreamAcl.Create(
                    options.PipeName,
                    PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | (firstInstance ? PipeOptions.FirstPipeInstance : PipeOptions.None),
                    inBufferSize: 4096,
                    outBufferSize: 4096,
                    security);
                firstInstance = false;

                await server.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                server?.Dispose();
                break;
            }
            catch (Exception ex)
            {
                server?.Dispose();
                slots.Release();
                LogError(ex, firstInstance
                    ? "Could not create the control pipe. Another process may be holding the pipe name. Retrying."
                    : "Control pipe error. Retrying.");
                try { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
                continue;
            }

            var connected = server;
            _ = Task.Run(async () =>
            {
                try { await HandleClientAsync(connected, stoppingToken).ConfigureAwait(false); }
                finally { slots.Release(); }
            }, CancellationToken.None);
        }
    }

    private async Task HandleClientAsync(NamedPipeServerStream pipe, CancellationToken stoppingToken)
    {
        using (pipe)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken))
        {
            timeout.CancelAfter(ClientTimeout);
            try
            {
                var request = await IpcFraming.ReadAsync<IpcRequest>(pipe, timeout.Token).ConfigureAwait(false);
                var response = processor.Handle(request);
                await IpcFraming.WriteAsync(pipe, response, timeout.Token).ConfigureAwait(false);

                // Wait for the client to close its end so the response is not discarded, bounded by the timeout.
                var probe = new byte[1];
                _ = await pipe.ReadAsync(probe, timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
            catch (IpcProtocolException ex)
            {
                logger.LogDebug(ex, "Rejected a malformed control request.");
                try
                {
                    await IpcFraming.WriteAsync(pipe, IpcResponse.Failure(IpcErrorCode.BadRequest, ex.Message), timeout.Token)
                        .ConfigureAwait(false);
                }
                catch
                {
                    // Client is gone.
                }
            }
            catch (IOException)
            {
                // Client disconnected.
            }
            catch (Exception ex)
            {
                LogError(ex, "Unexpected error handling a control request.");
            }
        }
    }

    private void LogError(Exception ex, string message)
    {
        bool log;
        lock (_errorLogGate)
            log = _errorLog.Register(message) is not null;
        if (log)
            logger.LogError(LogEvents.IpcError, ex, "{Message}", message);
    }

    private static PipeSecurity BuildSecurity(bool devMode)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        // ReadWrite deliberately excludes CreateNewInstance, so other accounts cannot add instances.
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));

        if (devMode)
        {
            // In development the service runs as the current user, who needs to create instances.
            security.AddAccessRule(new PipeAccessRule(
                WindowsIdentity.GetCurrent().User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        }

        return security;
    }
}
