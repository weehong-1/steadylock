using Microsoft.Extensions.Logging;
using SteadyVolume.Core.Config;
using SteadyVolume.Core.Ipc;
using SteadyVolume.Core.Security;

namespace SteadyVolume.Core.Control;

/// <summary>
/// The service's control logic: validates requests, checks passwords and lockout, updates and
/// persists the config, toggles tamper protection and tells the enforcer about the new target.
/// All requests are serialised by one lock, so lockout counting is exact.
/// </summary>
public sealed class CommandProcessor
{
    private readonly object _gate = new();
    private readonly IConfigStore _store;
    private readonly ITamperProtection _protection;
    private readonly ILogger _logger;
    private readonly LockoutTracker _lockout;
    private readonly int _hashIterations;
    private readonly string _version;
    private readonly IVolumeSnapshotProvider? _snapshots;
    private SteadyVolumeConfig _config;

    private static readonly TimeSpan CaptureTimeout = TimeSpan.FromSeconds(5);

    public CommandProcessor(
        IConfigStore store,
        SteadyVolumeConfig initialConfig,
        ITamperProtection protection,
        TimeProvider time,
        ILogger logger,
        int hashIterations = PasswordHasher.DefaultIterations,
        string? version = null,
        IVolumeSnapshotProvider? snapshots = null)
    {
        _snapshots = snapshots;
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _config = (initialConfig ?? throw new ArgumentNullException(nameof(initialConfig))).Clone();
        _protection = protection ?? throw new ArgumentNullException(nameof(protection));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        if (hashIterations < PasswordHasher.MinimumIterations)
            throw new ArgumentOutOfRangeException(nameof(hashIterations));
        _hashIterations = hashIterations;
        _version = version ?? typeof(CommandProcessor).Assembly.GetName().Version?.ToString(3) ?? "unknown";
        _lockout = new LockoutTracker(time, _config.FailedAttempts, _config.LockoutUntil);
    }

    /// <summary>Raised (under the lock) whenever what is enforced changes. Null means unlocked.</summary>
    public event Action<EnforcementTarget?>? TargetChanged;

    public EnforcementTarget? Target
    {
        get
        {
            lock (_gate)
                return EnforcementTarget.FromConfig(_config);
        }
    }

    /// <summary>
    /// Called (off the enforcement thread) when a device not in the current-levels lock was seen and
    /// held at the level it reported. Persists it so the level survives a restart. Ignored in other modes.
    /// </summary>
    public void RecordDiscoveredDevice(DeviceLevel device)
    {
        ArgumentNullException.ThrowIfNull(device);
        lock (_gate)
        {
            if (!_config.Locked || _config.Mode != LockMode.CurrentLevels ||
                _config.DeviceLevels.Any(d => d.Id == device.Id))
                return;

            try
            {
                var next = _config.Clone();
                next.DeviceLevels.Add(device.Clone());
                Persist(next);
                _logger.LogInformation(LogEvents.DeviceAdded,
                    "New output device {Device} locked at its current level, {Level}%.", device.Name ?? device.Id, device.Percent);
            }
            catch (Exception ex)
            {
                // Still enforced in memory; only persistence across restarts is lost.
                _logger.LogError(LogEvents.ConfigError, ex, "Could not save the level of new device {Device}.", device.Name ?? device.Id);
            }
        }
    }

    public StatusInfo GetStatus()
    {
        lock (_gate)
            return BuildStatus();
    }

    /// <summary>Re-applies tamper protection at service start if the config says it should be on.</summary>
    public void ApplyStartupState()
    {
        lock (_gate)
        {
            if (!_config.Protected)
                return;

            try
            {
                var next = _config.Clone();
                if (next.OriginalServiceSecurity is null)
                {
                    next.OriginalServiceSecurity = _protection.CaptureOriginal();
                    if (next.OriginalServiceSecurity is not null)
                        Persist(next);
                }

                _protection.Protect();
            }
            catch (Exception ex)
            {
                _logger.LogError(LogEvents.ProtectionError, ex, "Could not apply tamper protection at startup.");
            }
        }
    }

    public IpcResponse Handle(IpcRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ProtocolVersion != IpcRequest.CurrentProtocolVersion)
            return IpcResponse.Failure(IpcErrorCode.BadRequest,
                $"Unsupported protocol version {request.ProtocolVersion}; the CLI and service versions do not match.");

        lock (_gate)
        {
            try
            {
                return request.Command switch
                {
                    IpcCommand.Status => IpcResponse.Success(BuildStatus()),
                    IpcCommand.Setup => HandleSetup(request),
                    IpcCommand.Lock or IpcCommand.Unlock or IpcCommand.ChangePassword or IpcCommand.Unprotect
                        => HandlePasswordCommand(request),
                    _ => IpcResponse.Failure(IpcErrorCode.BadRequest, "Unknown command."),
                };
            }
            catch (Exception ex)
            {
                _logger.LogError(LogEvents.ConfigError, ex, "Command {Command} failed.", request.Command);
                return IpcResponse.Failure(IpcErrorCode.Internal, "The service could not complete the command: " + ex.Message);
            }
        }
    }

    private IpcResponse HandleSetup(IpcRequest request)
    {
        if (_config.Password is not null)
            return IpcResponse.Failure(IpcErrorCode.AlreadyConfigured,
                "A password already exists. Use 'passwd' to change it.");

        if (PasswordPolicy.Check(request.NewPassword) is { } problem)
            return IpcResponse.Failure(IpcErrorCode.WeakPassword, problem);

        var next = _config.Clone();
        next.Password = PasswordHasher.Hash(request.NewPassword!, _hashIterations);
        next.Protected = true;
        var warning = PrepareProtection(next);
        Persist(next);
        warning ??= ApplyProtection();

        _logger.LogInformation(LogEvents.PasswordCreated, "Password created during first-run setup.");
        return IpcResponse.Success(BuildStatus(), "Password created.", warning);
    }

    private IpcResponse HandlePasswordCommand(IpcRequest request)
    {
        if (_config.Password is null)
            return IpcResponse.Failure(IpcErrorCode.NotConfigured, "No password has been set yet. Run setup first.");

        // Validate arguments before the password so a typo in the level never costs an attempt.
        // A missing level is valid: it means "lock every device at its current level".
        if (request.Command == IpcCommand.Lock && request.Level is { } level && !VolumeMath.IsValidLevel(level))
            return IpcResponse.Failure(IpcErrorCode.InvalidLevel, "The level must be a whole number from 0 to 100.");
        if (request.Command == IpcCommand.Lock && request.Level is null && _snapshots is null)
            return IpcResponse.Failure(IpcErrorCode.Internal, "This service cannot read the current levels; give a level instead.");
        if (request.Command == IpcCommand.ChangePassword && PasswordPolicy.Check(request.NewPassword) is { } problem)
            return IpcResponse.Failure(IpcErrorCode.WeakPassword, problem);

        var stateBefore = (_lockout.FailedAttempts, _lockout.LockoutUntil);
        if (_lockout.IsLockedOut(out var remaining))
        {
            PersistLockoutIfChanged(stateBefore);
            _logger.LogWarning(LogEvents.RefusedLockedOut,
                "Refused {Command}: password commands are locked out for another {Seconds} s.",
                request.Command, SecondsUp(remaining));
            return new IpcResponse
            {
                Ok = false,
                Error = IpcErrorCode.LockedOut,
                Message = "Too many wrong passwords. Try again later.",
                RetryAfterSeconds = SecondsUp(remaining),
            };
        }

        bool verified;
        try
        {
            verified = PasswordHasher.Verify(request.Password, _config.Password);
        }
        catch (InvalidPasswordHashException ex)
        {
            _logger.LogError(LogEvents.ConfigError, ex, "The stored password hash is unusable.");
            return IpcResponse.Failure(IpcErrorCode.Internal, "The stored password hash is unusable: " + ex.Message);
        }

        if (!verified)
        {
            var startedLockout = _lockout.RecordFailure();
            PersistLockoutIfChanged(stateBefore);
            _logger.LogWarning(LogEvents.FailedPassword, "Wrong password for {Command}.", request.Command);
            if (startedLockout)
            {
                _logger.LogWarning(LogEvents.LockoutStarted,
                    "{Max} wrong passwords in a row. Password commands are refused for {Seconds} s.",
                    LockoutTracker.MaxAttempts, (int)LockoutTracker.LockoutDuration.TotalSeconds);
                return new IpcResponse
                {
                    Ok = false,
                    Error = IpcErrorCode.LockedOut,
                    Message = "Wrong password. Too many wrong passwords; try again later.",
                    RetryAfterSeconds = (int)LockoutTracker.LockoutDuration.TotalSeconds,
                };
            }

            return new IpcResponse
            {
                Ok = false,
                Error = IpcErrorCode.WrongPassword,
                Message = "Wrong password.",
                AttemptsRemaining = _lockout.AttemptsRemaining,
            };
        }

        _lockout.RecordSuccess();

        return request.Command switch
        {
            IpcCommand.Lock => request.Level is { } uniform ? DoLock(uniform) : DoLockAtCurrentLevels(),
            IpcCommand.Unlock => DoUnlock(),
            IpcCommand.ChangePassword => DoChangePassword(request.NewPassword!),
            IpcCommand.Unprotect => DoUnprotect(),
            _ => throw new InvalidOperationException(),
        };
    }

    private IpcResponse DoLock(int level)
    {
        var next = _config.Clone();
        next.Locked = true;
        next.Mode = LockMode.Uniform;
        next.Level = level;
        next.DeviceLevels.Clear();
        next.Protected = true; // locking always re-arms protection, e.g. after an unprotect
        var warning = PrepareProtection(next);
        Persist(next);
        warning ??= ApplyProtection();

        _logger.LogInformation(LogEvents.Locked, "Master volume locked at {Level}% on every output device.", level);
        TargetChanged?.Invoke(EnforcementTarget.FromConfig(_config));
        return IpcResponse.Success(BuildStatus(), $"Locked at {level}% on every output device.", warning);
    }

    private IpcResponse DoLockAtCurrentLevels()
    {
        IReadOnlyList<DeviceLevel> levels;
        try
        {
            levels = _snapshots!.CaptureCurrentLevels(CaptureTimeout);
        }
        catch (Exception ex)
        {
            Persist(_config.Clone()); // still save the reset failure counter
            _logger.LogError(LogEvents.AudioError, ex, "Could not read the current volume levels.");
            return IpcResponse.Failure(IpcErrorCode.Internal, "Could not read the current volume levels: " + ex.Message);
        }

        var next = _config.Clone();
        next.Locked = true;
        next.Mode = LockMode.CurrentLevels;
        next.DeviceLevels = levels.Select(l => l.Clone()).ToList();
        next.Protected = true;
        var warning = PrepareProtection(next);
        Persist(next);
        warning ??= ApplyProtection();

        var summary = string.Join(", ", levels.Select(l => $"{l.Name ?? l.Id} {l.Percent}%"));
        _logger.LogInformation(LogEvents.Locked,
            "Master volume locked at current levels on {Count} output device(s): {Devices}.", levels.Count, summary);
        TargetChanged?.Invoke(EnforcementTarget.FromConfig(_config));
        var message = levels.Count == 0
            ? "Locked. No output device is active right now; each device is held at its level when it first appears."
            : $"Locked {levels.Count} output device(s) at their current levels. Nothing was changed.";
        return IpcResponse.Success(BuildStatus(), message, warning);
    }

    private IpcResponse DoUnlock()
    {
        var next = _config.Clone();
        next.Locked = false;
        Persist(next);

        _logger.LogInformation(LogEvents.Unlocked, "Master volume unlocked.");
        TargetChanged?.Invoke(null);
        return IpcResponse.Success(BuildStatus(), "Unlocked. The volume is no longer enforced.");
    }

    private IpcResponse DoChangePassword(string newPassword)
    {
        var next = _config.Clone();
        next.Password = PasswordHasher.Hash(newPassword, _hashIterations);
        Persist(next);

        _logger.LogInformation(LogEvents.PasswordChanged, "Password changed.");
        return IpcResponse.Success(BuildStatus(), "Password changed.");
    }

    private IpcResponse DoUnprotect()
    {
        try
        {
            _protection.Restore(_config.OriginalServiceSecurity);
        }
        catch (Exception ex)
        {
            Persist(_config.Clone()); // still save the reset failure counter
            _logger.LogError(LogEvents.ProtectionError, ex, "Could not remove tamper protection.");
            return IpcResponse.Failure(IpcErrorCode.Internal, "Could not remove tamper protection: " + ex.Message);
        }

        var next = _config.Clone();
        next.Protected = false;
        Persist(next);

        _logger.LogInformation(LogEvents.Unprotected, "Tamper protection removed. The service can now be stopped and uninstalled.");
        return IpcResponse.Success(BuildStatus(),
            "Tamper protection removed. The service can now be stopped and uninstalled. 'lock' turns protection back on.");
    }

    /// <summary>Captures the pre-protection state into <paramref name="next"/> if not captured yet.</summary>
    private string? PrepareProtection(SteadyVolumeConfig next)
    {
        if (next.OriginalServiceSecurity is not null)
            return null;
        try
        {
            next.OriginalServiceSecurity = _protection.CaptureOriginal();
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogError(LogEvents.ProtectionError, ex, "Could not read the current service permissions.");
            return "Could not read the current service permissions: " + ex.Message;
        }
    }

    private string? ApplyProtection()
    {
        try
        {
            _protection.Protect();
            _logger.LogInformation(LogEvents.Protected, "Tamper protection is on.");
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogError(LogEvents.ProtectionError, ex, "Could not apply tamper protection.");
            return "Saved, but tamper protection could not be applied: " + ex.Message;
        }
    }

    /// <summary>Writes <paramref name="next"/> (plus the live lockout state) and only then makes it current.</summary>
    private void Persist(SteadyVolumeConfig next)
    {
        next.FailedAttempts = _lockout.FailedAttempts;
        next.LockoutUntil = _lockout.LockoutUntil;
        _store.Save(next);
        _config = next;
    }

    private void PersistLockoutIfChanged((int FailedAttempts, DateTimeOffset? LockoutUntil) before)
    {
        if (before == (_lockout.FailedAttempts, _lockout.LockoutUntil))
            return;
        try
        {
            Persist(_config.Clone());
        }
        catch (Exception ex)
        {
            // The in-memory counter still applies; only persistence across restarts is lost.
            _logger.LogError(LogEvents.ConfigError, ex, "Could not save the failed-attempt counter.");
        }
    }

    private StatusInfo BuildStatus() => new()
    {
        Locked = _config.Locked,
        Mode = _config.Mode,
        Level = _config.Level,
        Devices = _config.Mode == LockMode.CurrentLevels
            ? _config.DeviceLevels.Select(d => new DeviceStatus { Id = d.Id, Name = d.Name, Level = d.Percent }).ToList()
            : null,
        PasswordSet = _config.Password is not null,
        Protected = _config.Protected,
        ServiceVersion = _version,
    };

    private static int SecondsUp(TimeSpan span) => Math.Max(1, (int)Math.Ceiling(span.TotalSeconds));
}
