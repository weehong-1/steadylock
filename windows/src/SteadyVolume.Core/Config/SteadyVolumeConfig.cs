using SteadyVolume.Core.Security;

namespace SteadyVolume.Core.Config;

public enum LockMode
{
    /// <summary>Every output device is held at <see cref="SteadyVolumeConfig.Level"/>.</summary>
    Uniform,

    /// <summary>
    /// Every output device is held at the level it had when it was locked (<see cref="SteadyVolumeConfig.DeviceLevels"/>).
    /// Devices that appear later are held at the level they report when first seen.
    /// </summary>
    CurrentLevels,
}

/// <summary>One output device's locked level. <see cref="Scalar"/> is the exact 0.0-1.0 value read from the device.</summary>
public sealed class DeviceLevel
{
    public string Id { get; set; } = string.Empty;
    public string? Name { get; set; }
    public float Scalar { get; set; }

    [System.Text.Json.Serialization.JsonIgnore]
    public int Percent => VolumeMath.ToPercent(Scalar);

    public DeviceLevel Clone() => new() { Id = Id, Name = Name, Scalar = Scalar };
}

/// <summary>Everything the service persists. Only the service writes this file.</summary>
public sealed class SteadyVolumeConfig
{
    public const int CurrentSchemaVersion = 1;
    public const int DefaultLevel = 50;

    public int SchemaVersion { get; set; } = CurrentSchemaVersion;

    /// <summary>True while the master volume is being enforced.</summary>
    public bool Locked { get; set; }

    /// <summary>How the lock is defined. Missing in older files, which were always uniform.</summary>
    public LockMode Mode { get; set; } = LockMode.Uniform;

    /// <summary>The level to enforce in <see cref="LockMode.Uniform"/>, 0-100.</summary>
    public int Level { get; set; } = DefaultLevel;

    /// <summary>Per-device levels in <see cref="LockMode.CurrentLevels"/>.</summary>
    public List<DeviceLevel> DeviceLevels { get; set; } = new();

    /// <summary>Null until first-run setup has created a password.</summary>
    public PasswordHash? Password { get; set; }

    /// <summary>True while tamper protection should be applied.</summary>
    public bool Protected { get; set; }

    /// <summary>
    /// Platform-specific record of the protection state to restore on unprotect
    /// (on Windows: the service DACL in SDDL form, captured before it was tightened).
    /// </summary>
    public string? OriginalServiceSecurity { get; set; }

    public int FailedAttempts { get; set; }

    public DateTimeOffset? LockoutUntil { get; set; }

    public void Validate()
    {
        if (SchemaVersion != CurrentSchemaVersion)
            throw new ConfigException($"Unsupported config schema version {SchemaVersion}.");
        if (!Enum.IsDefined(Mode))
            throw new ConfigException($"Unknown lock mode {Mode}.");
        if (!VolumeMath.IsValidLevel(Level))
            throw new ConfigException($"Level {Level} is outside 0-100.");
        if (FailedAttempts < 0)
            throw new ConfigException("FailedAttempts cannot be negative.");
        if (DeviceLevels is null)
            throw new ConfigException("DeviceLevels cannot be null.");

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var device in DeviceLevels)
        {
            if (device is null || string.IsNullOrWhiteSpace(device.Id))
                throw new ConfigException("A device level has no device ID.");
            if (!ids.Add(device.Id))
                throw new ConfigException($"Device {device.Id} is listed twice.");
            if (!float.IsFinite(device.Scalar) || device.Scalar < 0f || device.Scalar > 1f)
                throw new ConfigException($"Device {device.Id} has level {device.Scalar}, outside 0.0-1.0.");
        }

        try
        {
            Password?.Validate();
        }
        catch (InvalidPasswordHashException ex)
        {
            throw new ConfigException("The stored password hash is invalid: " + ex.Message, ex);
        }
    }

    public SteadyVolumeConfig Clone() => new()
    {
        SchemaVersion = SchemaVersion,
        Locked = Locked,
        Mode = Mode,
        Level = Level,
        DeviceLevels = DeviceLevels.Select(d => d.Clone()).ToList(),
        Password = Password, // immutable record
        Protected = Protected,
        OriginalServiceSecurity = OriginalServiceSecurity,
        FailedAttempts = FailedAttempts,
        LockoutUntil = LockoutUntil,
    };
}

public sealed class ConfigException : Exception
{
    public ConfigException(string message) : base(message) { }
    public ConfigException(string message, Exception inner) : base(message, inner) { }
}
