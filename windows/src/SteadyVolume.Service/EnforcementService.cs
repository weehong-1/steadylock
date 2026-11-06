using System.Runtime.Versioning;
using SteadyVolume.Core.Config;
using SteadyVolume.Core.Control;

namespace SteadyVolume.Service;

[SupportedOSPlatform("windows")]
internal sealed class EnforcementService(
    CommandProcessor processor,
    VolumeEnforcer enforcer,
    ServiceOptions options,
    ILogger<EnforcementService> logger) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken)
    {
        var status = processor.GetStatus();
        var lockText = !status.Locked ? "no"
            : status.Mode == LockMode.CurrentLevels ? $"yes, at current levels on {status.Devices?.Count ?? 0} device(s)"
            : $"yes, at {status.Level}% on every device";
        logger.LogInformation(LogEvents.ServiceStarted,
            "SteadyVolume {Version} started{Mode}. Locked: {Locked}. Protection: {Protected}. Password set: {PasswordSet}.",
            status.ServiceVersion,
            options.DevMode ? (options.DryRun ? " in development mode (dry run)" : " in development mode") : "",
            lockText,
            status.Protected ? "on" : "off",
            status.PasswordSet ? "yes" : "no");

        processor.ApplyStartupState();
        processor.TargetChanged += enforcer.SetTarget;
        enforcer.DeviceDiscovered += processor.RecordDiscoveredDevice;
        enforcer.SetTarget(processor.Target);
        enforcer.Start();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        logger.LogInformation(LogEvents.ServiceStopping, "SteadyVolume is stopping.");
        processor.TargetChanged -= enforcer.SetTarget;
        enforcer.DeviceDiscovered -= processor.RecordDiscoveredDevice;
        enforcer.Stop();
        return Task.CompletedTask;
    }
}
