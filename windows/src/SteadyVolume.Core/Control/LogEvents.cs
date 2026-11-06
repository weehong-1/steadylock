using Microsoft.Extensions.Logging;

namespace SteadyVolume.Core.Control;

/// <summary>Event IDs. On Windows these become the Event Log event IDs.</summary>
public static class LogEvents
{
    public static readonly EventId ServiceStarted = new(1000, nameof(ServiceStarted));
    public static readonly EventId ServiceStopping = new(1001, nameof(ServiceStopping));
    public static readonly EventId PasswordCreated = new(1100, nameof(PasswordCreated));
    public static readonly EventId Locked = new(1101, nameof(Locked));
    public static readonly EventId Unlocked = new(1102, nameof(Unlocked));
    public static readonly EventId PasswordChanged = new(1103, nameof(PasswordChanged));
    public static readonly EventId Unprotected = new(1104, nameof(Unprotected));
    public static readonly EventId Protected = new(1105, nameof(Protected));
    public static readonly EventId DeviceAdded = new(1106, nameof(DeviceAdded));
    public static readonly EventId FailedPassword = new(2000, nameof(FailedPassword));
    public static readonly EventId LockoutStarted = new(2001, nameof(LockoutStarted));
    public static readonly EventId RefusedLockedOut = new(2002, nameof(RefusedLockedOut));
    public static readonly EventId VolumeReverted = new(3000, nameof(VolumeReverted));
    public static readonly EventId DevicesChanged = new(3001, nameof(DevicesChanged));
    public static readonly EventId ConfigError = new(9000, nameof(ConfigError));
    public static readonly EventId ProtectionError = new(9001, nameof(ProtectionError));
    public static readonly EventId AudioError = new(9002, nameof(AudioError));
    public static readonly EventId IpcError = new(9003, nameof(IpcError));
}
