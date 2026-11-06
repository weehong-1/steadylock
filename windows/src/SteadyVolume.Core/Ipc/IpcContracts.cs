namespace SteadyVolume.Core.Ipc;

// Wire format (shared with the macOS version):
//   [4-byte little-endian length][UTF-8 JSON], one request and one response per connection.
//   Property names are camelCase, enum values are camelCase strings.

public enum IpcCommand
{
    Status,
    Setup,
    Lock,
    Unlock,
    ChangePassword,
    Unprotect,
}

public enum IpcErrorCode
{
    None,
    BadRequest,
    NotConfigured,
    AlreadyConfigured,
    WrongPassword,
    LockedOut,
    InvalidLevel,
    WeakPassword,
    Internal,
}

public sealed class IpcRequest
{
    public const int CurrentProtocolVersion = 1;

    public int ProtocolVersion { get; set; } = CurrentProtocolVersion;
    public IpcCommand Command { get; set; }
    public string? Password { get; set; }
    public string? NewPassword { get; set; }

    /// <summary>For <see cref="IpcCommand.Lock"/>: a level for every device, or null to lock each device at its current level.</summary>
    public int? Level { get; set; }
}

public sealed class IpcResponse
{
    public bool Ok { get; set; }
    public IpcErrorCode Error { get; set; }
    public string? Message { get; set; }

    /// <summary>Set when the command succeeded but a secondary step (e.g. tamper protection) failed.</summary>
    public string? Warning { get; set; }

    public int? RetryAfterSeconds { get; set; }
    public int? AttemptsRemaining { get; set; }
    public StatusInfo? Status { get; set; }

    public static IpcResponse Success(StatusInfo status, string? message = null, string? warning = null) =>
        new() { Ok = true, Error = IpcErrorCode.None, Status = status, Message = message, Warning = warning };

    public static IpcResponse Failure(IpcErrorCode error, string message) =>
        new() { Ok = false, Error = error, Message = message };
}

public sealed class StatusInfo
{
    public bool Locked { get; set; }
    public Config.LockMode Mode { get; set; }

    /// <summary>The uniform level (meaningful in uniform mode).</summary>
    public int Level { get; set; }

    /// <summary>Per-device locked levels in current-levels mode, otherwise null.</summary>
    public List<DeviceStatus>? Devices { get; set; }
    public bool PasswordSet { get; set; }
    public bool Protected { get; set; }
    public string? ServiceVersion { get; set; }
}

public sealed class DeviceStatus
{
    public string? Name { get; set; }
    public string Id { get; set; } = string.Empty;
    public int Level { get; set; }
}
