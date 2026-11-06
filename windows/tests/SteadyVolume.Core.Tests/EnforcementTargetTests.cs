using SteadyVolume.Core.Config;
using SteadyVolume.Core.Control;

namespace SteadyVolume.Core.Tests;

public class EnforcementTargetTests
{
    [Fact]
    public void Unlocked_config_has_no_target()
    {
        Assert.Null(EnforcementTarget.FromConfig(new SteadyVolumeConfig { Locked = false, Level = 30 }));
    }

    [Fact]
    public void Uniform_target_gives_every_device_the_same_level_and_adopts_nothing()
    {
        var target = EnforcementTarget.FromConfig(new SteadyVolumeConfig { Locked = true, Level = 30 })!;
        Assert.Equal(30, target.UniformLevel);
        Assert.False(target.CaptureNewDevices);
        Assert.Equal(0.30f, target.ScalarFor("any device"));
    }

    [Fact]
    public void Current_levels_target_gives_each_device_its_own_exact_level()
    {
        var config = new SteadyVolumeConfig
        {
            Locked = true,
            Mode = LockMode.CurrentLevels,
            Level = 30, // ignored in this mode
            DeviceLevels =
            [
                new DeviceLevel { Id = "a", Scalar = 1.0f },
                new DeviceLevel { Id = "b", Scalar = 0.499846f },
            ],
        };

        var target = EnforcementTarget.FromConfig(config)!;
        Assert.Null(target.UniformLevel);
        Assert.True(target.CaptureNewDevices);
        Assert.Equal(1.0f, target.ScalarFor("a"));
        Assert.Equal(0.499846f, target.ScalarFor("b"));
        Assert.Null(target.ScalarFor("new device")); // held where it is when first seen
    }

    [Fact]
    public void Target_is_a_snapshot_of_the_config()
    {
        var config = new SteadyVolumeConfig
        {
            Locked = true,
            Mode = LockMode.CurrentLevels,
            DeviceLevels = [new DeviceLevel { Id = "a", Scalar = 0.2f }],
        };
        var target = EnforcementTarget.FromConfig(config)!;
        config.DeviceLevels[0].Scalar = 0.9f;
        Assert.Equal(0.2f, target.ScalarFor("a"));
    }
}
