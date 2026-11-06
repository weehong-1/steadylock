using SteadyVolume.Core.Config;

namespace SteadyVolume.Core.Control;

/// <summary>
/// What the enforcer should hold each output device at. Immutable, so it can be handed from the
/// control thread to the enforcement thread by a single reference assignment.
/// </summary>
public sealed class EnforcementTarget
{
    private EnforcementTarget(int? uniformLevel, IReadOnlyDictionary<string, float> deviceLevels, bool captureNewDevices)
    {
        UniformLevel = uniformLevel;
        DeviceLevels = deviceLevels;
        CaptureNewDevices = captureNewDevices;
    }

    /// <summary>Set in uniform mode: every device is held at this percent.</summary>
    public int? UniformLevel { get; }

    /// <summary>Exact scalars per device ID, in current-levels mode.</summary>
    public IReadOnlyDictionary<string, float> DeviceLevels { get; }

    /// <summary>True in current-levels mode: a device not in <see cref="DeviceLevels"/> is held at the level it has when first seen.</summary>
    public bool CaptureNewDevices { get; }

    public static EnforcementTarget Uniform(int level)
    {
        if (!VolumeMath.IsValidLevel(level)) throw new ArgumentOutOfRangeException(nameof(level));
        return new EnforcementTarget(level, new Dictionary<string, float>(), captureNewDevices: false);
    }

    public static EnforcementTarget CurrentLevels(IEnumerable<DeviceLevel> levels) =>
        new(null, levels.ToDictionary(d => d.Id, d => d.Scalar, StringComparer.Ordinal), captureNewDevices: true);

    /// <summary>Null when the config is unlocked.</summary>
    public static EnforcementTarget? FromConfig(SteadyVolumeConfig config)
    {
        if (!config.Locked)
            return null;
        return config.Mode == LockMode.CurrentLevels ? CurrentLevels(config.DeviceLevels) : Uniform(config.Level);
    }

    /// <summary>
    /// The exact scalar to hold <paramref name="deviceId"/> at, or null when this target has no level for it
    /// (current-levels mode and the device has not been seen yet).
    /// </summary>
    public float? ScalarFor(string deviceId)
    {
        if (DeviceLevels.TryGetValue(deviceId, out var scalar))
            return scalar;
        return UniformLevel is { } level ? VolumeMath.ToScalar(level) : null;
    }
}

/// <summary>Reads the current level of every active output device. Implemented by the enforcer.</summary>
public interface IVolumeSnapshotProvider
{
    /// <summary>Throws <see cref="TimeoutException"/> if the audio system does not answer in time.</summary>
    IReadOnlyList<DeviceLevel> CaptureCurrentLevels(TimeSpan timeout);
}
