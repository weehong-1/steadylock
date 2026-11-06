using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;
using SteadyVolume.Core.Config;
using SteadyVolume.Core.Control;
using SteadyVolume.Core.Ipc;
using SteadyVolume.Core.Security;

namespace SteadyVolume.Core.Tests;

public class CommandProcessorTests
{
    private const string Password = "correct horse";
    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero));
    private readonly InMemoryStore _store = new();
    private readonly FakeProtection _protection = new();
    private readonly FakeSnapshots _snapshots = new();
    private readonly List<EnforcementTarget?> _targetObjects = new();

    /// <summary>Uniform level of each target the enforcer was given (null = unlocked).</summary>
    private List<int?> _targets => _targetObjects.Select(t => t?.UniformLevel).ToList();

    private CommandProcessor Create(SteadyVolumeConfig? config = null, bool withSnapshots = true)
    {
        var processor = new CommandProcessor(_store, config ?? _store.Load(), _protection, _time, NullLogger.Instance,
            PasswordHasher.MinimumIterations, "test", withSnapshots ? _snapshots : null);
        processor.TargetChanged += _targetObjects.Add;
        return processor;
    }

    private static int? UniformLevel(CommandProcessor processor) => processor.Target?.UniformLevel;

    private CommandProcessor CreateConfigured()
    {
        var processor = Create();
        Assert.True(processor.Handle(new IpcRequest { Command = IpcCommand.Setup, NewPassword = Password }).Ok);
        return processor;
    }

    private static IpcRequest Req(IpcCommand command, string? password = Password, int? level = null, string? newPassword = null) =>
        new() { Command = command, Password = password, Level = level, NewPassword = newPassword };

    [Fact]
    public void Status_needs_no_password()
    {
        var response = Create().Handle(new IpcRequest { Command = IpcCommand.Status });
        Assert.True(response.Ok);
        Assert.False(response.Status!.PasswordSet);
        Assert.False(response.Status.Locked);
    }

    [Fact]
    public void Password_commands_before_setup_report_not_configured()
    {
        var response = Create().Handle(Req(IpcCommand.Lock, level: 30));
        Assert.Equal(IpcErrorCode.NotConfigured, response.Error);
    }

    [Fact]
    public void Setup_creates_password_turns_on_protection_and_persists()
    {
        var processor = CreateConfigured();

        Assert.NotNull(_store.Saved!.Password);
        Assert.True(_store.Saved.Protected);
        Assert.Equal(1, _protection.ProtectCalls);
        Assert.Equal("original-dacl", _store.Saved.OriginalServiceSecurity);
        Assert.True(processor.GetStatus().PasswordSet);
    }

    [Fact]
    public void Setup_twice_is_refused()
    {
        var processor = CreateConfigured();
        var response = processor.Handle(new IpcRequest { Command = IpcCommand.Setup, NewPassword = "another password" });
        Assert.Equal(IpcErrorCode.AlreadyConfigured, response.Error);
    }

    [Fact]
    public void Setup_with_weak_password_is_refused()
    {
        var response = Create().Handle(new IpcRequest { Command = IpcCommand.Setup, NewPassword = "short" });
        Assert.Equal(IpcErrorCode.WeakPassword, response.Error);
        Assert.Null(_store.Saved);
    }

    [Fact]
    public void Lock_with_correct_password_locks_and_notifies_enforcer()
    {
        var processor = CreateConfigured();
        var response = processor.Handle(Req(IpcCommand.Lock, level: 35));

        Assert.True(response.Ok);
        Assert.True(_store.Saved!.Locked);
        Assert.Equal(35, _store.Saved.Level);
        Assert.Equal(35, UniformLevel(processor));
        Assert.Equal([35], _targets);
    }

    [Fact]
    public void Unlock_stops_enforcement()
    {
        var processor = CreateConfigured();
        processor.Handle(Req(IpcCommand.Lock, level: 35));
        var response = processor.Handle(Req(IpcCommand.Unlock));

        Assert.True(response.Ok);
        Assert.False(_store.Saved!.Locked);
        Assert.Null(UniformLevel(processor));
        Assert.Equal([35, null], _targets);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(101)]
    public void Invalid_level_is_refused_without_costing_an_attempt(int level)
    {
        var processor = CreateConfigured();
        var response = processor.Handle(Req(IpcCommand.Lock, password: "wrong password", level: level));

        Assert.Equal(IpcErrorCode.InvalidLevel, response.Error);
        Assert.Equal(0, _store.Saved!.FailedAttempts);
    }

    // ---- lock at current levels --------------------------------------------------------------

    [Fact]
    public void Lock_without_level_holds_every_device_at_its_exact_current_level()
    {
        _snapshots.Levels =
        [
            new DeviceLevel { Id = "speakers", Name = "Speakers", Scalar = 1.0f },
            new DeviceLevel { Id = "ae9", Name = "Sound Blaster AE-9", Scalar = 0.499846f },
        ];
        var processor = CreateConfigured();

        var response = processor.Handle(Req(IpcCommand.Lock));

        Assert.True(response.Ok, response.Message);
        Assert.Equal(1, _snapshots.Calls);
        var saved = _store.Saved!;
        Assert.True(saved.Locked);
        Assert.Equal(LockMode.CurrentLevels, saved.Mode);
        Assert.Equal(0.499846f, saved.DeviceLevels.Single(d => d.Id == "ae9").Scalar); // exact, not rounded
        Assert.True(saved.Protected);

        var target = Assert.Single(_targetObjects)!;
        Assert.Null(target.UniformLevel);
        Assert.True(target.CaptureNewDevices);
        Assert.Equal(1.0f, target.ScalarFor("speakers"));
        Assert.Equal(0.499846f, target.ScalarFor("ae9"));
        Assert.Null(target.ScalarFor("headphones-plugged-in-later"));

        var status = response.Status!;
        Assert.Equal(LockMode.CurrentLevels, status.Mode);
        Assert.Equal([50, 100], status.Devices!.Select(d => d.Level).OrderBy(l => l));
    }

    [Fact]
    public void Lock_without_level_checks_the_password_before_reading_levels()
    {
        var processor = CreateConfigured();
        var response = processor.Handle(Req(IpcCommand.Lock, password: "wrong password"));

        Assert.Equal(IpcErrorCode.WrongPassword, response.Error);
        Assert.Equal(0, _snapshots.Calls);
        Assert.False(_store.Saved!.Locked);
    }

    [Fact]
    public void Lock_without_level_fails_cleanly_when_levels_cannot_be_read()
    {
        _snapshots.Throw = new TimeoutException("The audio system did not answer in time.");
        var processor = CreateConfigured();

        var response = processor.Handle(Req(IpcCommand.Lock));

        Assert.Equal(IpcErrorCode.Internal, response.Error);
        Assert.False(_store.Saved!.Locked);
        Assert.Empty(_targetObjects);
    }

    [Fact]
    public void Lock_without_level_is_refused_when_the_service_cannot_read_levels()
    {
        var processor = Create(withSnapshots: false);
        Assert.True(processor.Handle(new IpcRequest { Command = IpcCommand.Setup, NewPassword = Password }).Ok);

        var response = processor.Handle(Req(IpcCommand.Lock));

        Assert.False(response.Ok);
        Assert.Equal(0, _store.Saved!.FailedAttempts);
        Assert.False(_store.Saved.Locked);
    }

    [Fact]
    public void Device_seen_later_is_recorded_at_its_level_and_survives_a_restart()
    {
        _snapshots.Levels = [new DeviceLevel { Id = "speakers", Name = "Speakers", Scalar = 0.8f }];
        var processor = CreateConfigured();
        processor.Handle(Req(IpcCommand.Lock));

        processor.RecordDiscoveredDevice(new DeviceLevel { Id = "headphones", Name = "Headphones", Scalar = 0.25f });
        processor.RecordDiscoveredDevice(new DeviceLevel { Id = "headphones", Name = "Headphones", Scalar = 0.9f }); // ignored

        Assert.Equal(0.25f, _store.Saved!.DeviceLevels.Single(d => d.Id == "headphones").Scalar);
        var restarted = Create(_store.Load());
        Assert.Equal(0.25f, restarted.Target!.ScalarFor("headphones"));
        Assert.Equal(0.8f, restarted.Target!.ScalarFor("speakers"));
    }

    [Theory]
    [InlineData(false)] // unlocked
    [InlineData(true)]  // locked at one level for every device
    public void Discovered_devices_are_ignored_outside_a_current_levels_lock(bool uniformLock)
    {
        var processor = CreateConfigured();
        if (uniformLock)
            processor.Handle(Req(IpcCommand.Lock, level: 30));

        processor.RecordDiscoveredDevice(new DeviceLevel { Id = "headphones", Scalar = 0.25f });

        Assert.Empty(_store.Saved!.DeviceLevels);
    }

    [Fact]
    public void Lock_with_a_level_replaces_a_current_levels_lock()
    {
        _snapshots.Levels = [new DeviceLevel { Id = "speakers", Scalar = 0.8f }];
        var processor = CreateConfigured();
        processor.Handle(Req(IpcCommand.Lock));

        Assert.True(processor.Handle(Req(IpcCommand.Lock, level: 40)).Ok);

        Assert.Equal(LockMode.Uniform, _store.Saved!.Mode);
        Assert.Empty(_store.Saved.DeviceLevels);
        Assert.Equal(VolumeMath.ToScalar(40), processor.Target!.ScalarFor("speakers"));
        Assert.Equal(VolumeMath.ToScalar(40), processor.Target!.ScalarFor("anything-else"));
    }

    [Fact]
    public void Unlock_after_current_levels_lock_stops_enforcement()
    {
        _snapshots.Levels = [new DeviceLevel { Id = "speakers", Scalar = 0.8f }];
        var processor = CreateConfigured();
        processor.Handle(Req(IpcCommand.Lock));

        Assert.True(processor.Handle(Req(IpcCommand.Unlock)).Ok);
        Assert.Null(processor.Target);
        Assert.Null(_targetObjects.Last());
    }

    [Fact]
    public void Wrong_password_is_refused_and_counted()
    {
        var processor = CreateConfigured();
        var response = processor.Handle(Req(IpcCommand.Unlock, password: "wrong password"));

        Assert.Equal(IpcErrorCode.WrongPassword, response.Error);
        Assert.Equal(4, response.AttemptsRemaining);
        Assert.Equal(1, _store.Saved!.FailedAttempts);
    }

    [Fact]
    public void Five_wrong_passwords_refuse_all_password_commands_for_30_seconds()
    {
        var processor = CreateConfigured();
        processor.Handle(Req(IpcCommand.Lock, level: 40));

        for (var i = 0; i < 4; i++)
            Assert.Equal(IpcErrorCode.WrongPassword, processor.Handle(Req(IpcCommand.Unlock, password: "nope nope")).Error);

        var fifth = processor.Handle(Req(IpcCommand.Unlock, password: "nope nope"));
        Assert.Equal(IpcErrorCode.LockedOut, fifth.Error);
        Assert.Equal(30, fifth.RetryAfterSeconds);

        // Even the right password is refused during the lockout, for every password command.
        foreach (var command in new[] { IpcCommand.Unlock, IpcCommand.ChangePassword, IpcCommand.Unprotect })
        {
            var refused = processor.Handle(Req(command, newPassword: "new password 1"));
            Assert.Equal(IpcErrorCode.LockedOut, refused.Error);
        }

        Assert.Equal(IpcErrorCode.LockedOut, processor.Handle(Req(IpcCommand.Lock, level: 10)).Error);
        Assert.True(processor.GetStatus().Locked);
        Assert.Equal(40, processor.GetStatus().Level);

        // Status is still allowed.
        Assert.True(processor.Handle(new IpcRequest { Command = IpcCommand.Status }).Ok);

        _time.Advance(TimeSpan.FromSeconds(30));
        Assert.True(processor.Handle(Req(IpcCommand.Unlock)).Ok);
    }

    [Fact]
    public void Lockout_survives_a_service_restart()
    {
        var processor = CreateConfigured();
        for (var i = 0; i < 5; i++)
            processor.Handle(Req(IpcCommand.Unlock, password: "nope nope"));

        _time.Advance(TimeSpan.FromSeconds(5));
        var restarted = Create(_store.Load());
        var response = restarted.Handle(Req(IpcCommand.Unlock));
        Assert.Equal(IpcErrorCode.LockedOut, response.Error);
        Assert.Equal(25, response.RetryAfterSeconds);
    }

    [Fact]
    public void Correct_password_resets_the_failure_count()
    {
        var processor = CreateConfigured();
        for (var i = 0; i < 4; i++)
            processor.Handle(Req(IpcCommand.Unlock, password: "nope nope"));

        Assert.True(processor.Handle(Req(IpcCommand.Unlock)).Ok);
        Assert.Equal(0, _store.Saved!.FailedAttempts);
        Assert.Equal(4, processor.Handle(Req(IpcCommand.Unlock, password: "nope nope")).AttemptsRemaining);
    }

    [Fact]
    public void Change_password_requires_old_password_and_switches_to_new_one()
    {
        var processor = CreateConfigured();
        Assert.Equal(IpcErrorCode.WrongPassword,
            processor.Handle(Req(IpcCommand.ChangePassword, password: "wrong one", newPassword: "brand new pass")).Error);

        Assert.True(processor.Handle(Req(IpcCommand.ChangePassword, newPassword: "brand new pass")).Ok);
        Assert.Equal(IpcErrorCode.WrongPassword, processor.Handle(Req(IpcCommand.Unlock)).Error);
        Assert.True(processor.Handle(Req(IpcCommand.Unlock, password: "brand new pass")).Ok);
    }

    [Fact]
    public void Change_password_rejects_weak_new_password_before_checking_old()
    {
        var processor = CreateConfigured();
        var response = processor.Handle(Req(IpcCommand.ChangePassword, password: "wrong", newPassword: "x"));
        Assert.Equal(IpcErrorCode.WeakPassword, response.Error);
        Assert.Equal(0, _store.Saved!.FailedAttempts);
    }

    [Fact]
    public void Unprotect_restores_original_security_and_lock_rearms_protection()
    {
        var processor = CreateConfigured();
        var response = processor.Handle(Req(IpcCommand.Unprotect));

        Assert.True(response.Ok);
        Assert.Equal(["original-dacl"], _protection.Restored);
        Assert.False(_store.Saved!.Protected);

        processor.Handle(Req(IpcCommand.Lock, level: 50));
        Assert.True(_store.Saved.Protected);
        Assert.Equal(2, _protection.ProtectCalls);
    }

    [Fact]
    public void Unprotect_failure_keeps_protected_flag()
    {
        var processor = CreateConfigured();
        _protection.FailRestore = true;
        var response = processor.Handle(Req(IpcCommand.Unprotect));

        Assert.Equal(IpcErrorCode.Internal, response.Error);
        Assert.True(_store.Saved!.Protected);
    }

    [Fact]
    public void Protection_failure_on_lock_is_reported_as_warning_but_lock_still_applies()
    {
        var processor = CreateConfigured();
        _protection.FailProtect = true;
        var response = processor.Handle(Req(IpcCommand.Lock, level: 20));

        Assert.True(response.Ok);
        Assert.NotNull(response.Warning);
        Assert.Equal(20, UniformLevel(processor));
    }

    [Fact]
    public void Failed_save_leaves_previous_state_in_effect()
    {
        var processor = CreateConfigured();
        _store.FailSaves = true;
        var response = processor.Handle(Req(IpcCommand.Lock, level: 20));

        Assert.Equal(IpcErrorCode.Internal, response.Error);
        Assert.Null(UniformLevel(processor));
        Assert.Empty(_targets);
    }

    [Fact]
    public void Startup_reapplies_protection_when_configured()
    {
        CreateConfigured();
        var restarted = Create(_store.Load());
        restarted.ApplyStartupState();
        Assert.Equal(2, _protection.ProtectCalls);
    }

    [Fact]
    public void Mismatched_protocol_version_is_refused()
    {
        var response = Create().Handle(new IpcRequest { ProtocolVersion = 99, Command = IpcCommand.Status });
        Assert.Equal(IpcErrorCode.BadRequest, response.Error);
    }

    private sealed class InMemoryStore : IConfigStore
    {
        public SteadyVolumeConfig? Saved { get; private set; }
        public bool FailSaves { get; set; }

        public SteadyVolumeConfig Load() => Saved?.Clone() ?? new SteadyVolumeConfig();

        public void Save(SteadyVolumeConfig config)
        {
            if (FailSaves)
                throw new IOException("disk full");
            config.Validate();
            Saved = config.Clone();
        }
    }

    private sealed class FakeSnapshots : IVolumeSnapshotProvider
    {
        public List<DeviceLevel> Levels { get; set; } = new();
        public Exception? Throw { get; set; }
        public int Calls { get; private set; }

        public IReadOnlyList<DeviceLevel> CaptureCurrentLevels(TimeSpan timeout)
        {
            Calls++;
            if (Throw is not null)
                throw Throw;
            return Levels.Select(l => l.Clone()).ToList();
        }
    }

    private sealed class FakeProtection : ITamperProtection
    {
        public int ProtectCalls { get; private set; }
        public List<string?> Restored { get; } = new();
        public bool FailProtect { get; set; }
        public bool FailRestore { get; set; }

        public string? CaptureOriginal() => "original-dacl";

        public void Protect()
        {
            if (FailProtect)
                throw new UnauthorizedAccessException("denied");
            ProtectCalls++;
        }

        public void Restore(string? original)
        {
            if (FailRestore)
                throw new UnauthorizedAccessException("denied");
            Restored.Add(original);
        }
    }
}
