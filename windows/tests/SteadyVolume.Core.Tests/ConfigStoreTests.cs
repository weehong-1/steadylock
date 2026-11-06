using System.Text.Json.Nodes;
using SteadyVolume.Core.Config;
using SteadyVolume.Core.Security;

namespace SteadyVolume.Core.Tests;

public sealed class ConfigStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "steadyvolume-tests-" + Guid.NewGuid().ToString("N"));
    private string ConfigPath => Path.Combine(_dir, "config.json");

    public void Dispose()
    {
        if (Directory.Exists(_dir))
            Directory.Delete(_dir, recursive: true);
    }

    [Fact]
    public void Missing_file_loads_defaults_unlocked_without_password()
    {
        var config = new ConfigStore(ConfigPath).Load();
        Assert.False(config.Locked);
        Assert.Null(config.Password);
        Assert.False(config.Protected);
        Assert.Equal(SteadyVolumeConfig.DefaultLevel, config.Level);
    }

    [Fact]
    public void Save_then_load_round_trips_every_field()
    {
        var store = new ConfigStore(ConfigPath);
        var original = new SteadyVolumeConfig
        {
            Locked = true,
            Level = 37,
            Password = PasswordHasher.Hash("password1", PasswordHasher.MinimumIterations),
            Protected = true,
            OriginalServiceSecurity = "D:(A;;CC;;;SY)",
            FailedAttempts = 3,
            LockoutUntil = new DateTimeOffset(2026, 11, 6, 12, 0, 30, TimeSpan.Zero),
        };

        store.Save(original);
        var loaded = store.Load();

        Assert.True(loaded.Locked);
        Assert.Equal(37, loaded.Level);
        Assert.Equal(original.Password, loaded.Password);
        Assert.True(loaded.Protected);
        Assert.Equal("D:(A;;CC;;;SY)", loaded.OriginalServiceSecurity);
        Assert.Equal(3, loaded.FailedAttempts);
        Assert.Equal(original.LockoutUntil, loaded.LockoutUntil);
    }

    [Fact]
    public void File_uses_camelCase_json()
    {
        new ConfigStore(ConfigPath).Save(new SteadyVolumeConfig { Locked = true, Level = 20 });
        var json = JsonNode.Parse(File.ReadAllText(ConfigPath))!.AsObject();
        Assert.True(json["locked"]!.GetValue<bool>());
        Assert.Equal(20, json["level"]!.GetValue<int>());
        Assert.Equal(1, json["schemaVersion"]!.GetValue<int>());
    }

    [Fact]
    public void Second_save_keeps_previous_version_as_backup_and_leaves_no_temp_file()
    {
        var store = new ConfigStore(ConfigPath);
        store.Save(new SteadyVolumeConfig { Level = 10 });
        store.Save(new SteadyVolumeConfig { Level = 20 });

        Assert.True(File.Exists(store.BackupPath));
        Assert.False(File.Exists(ConfigPath + ".tmp"));
        Assert.Equal(20, store.Load().Level);
        Assert.Contains("10", File.ReadAllText(store.BackupPath));
    }

    [Fact]
    public void Corrupt_main_file_falls_back_to_backup()
    {
        var store = new ConfigStore(ConfigPath);
        store.Save(new SteadyVolumeConfig { Locked = true, Level = 10 });
        store.Save(new SteadyVolumeConfig { Locked = true, Level = 20 });
        File.WriteAllText(ConfigPath, "{ this is not json");

        var loaded = store.Load();
        Assert.True(loaded.Locked);
        Assert.Equal(10, loaded.Level);
    }

    [Fact]
    public void Both_files_corrupt_throws_config_exception()
    {
        var store = new ConfigStore(ConfigPath);
        store.Save(new SteadyVolumeConfig());
        store.Save(new SteadyVolumeConfig());
        File.WriteAllText(ConfigPath, "garbage");
        File.WriteAllText(store.BackupPath, "");

        Assert.Throws<ConfigException>(() => store.Load());
    }

    [Fact]
    public void Corrupt_main_file_without_backup_throws_config_exception()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(ConfigPath, "null");
        Assert.Throws<ConfigException>(() => new ConfigStore(ConfigPath).Load());
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(101)]
    public void Saving_an_out_of_range_level_is_refused(int level)
    {
        var store = new ConfigStore(ConfigPath);
        Assert.Throws<ConfigException>(() => store.Save(new SteadyVolumeConfig { Level = level }));
        Assert.False(File.Exists(ConfigPath));
    }

    [Fact]
    public void Out_of_range_level_in_file_is_treated_as_corrupt()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(ConfigPath, """{ "schemaVersion": 1, "locked": true, "level": 250 }""");
        Assert.Throws<ConfigException>(() => new ConfigStore(ConfigPath).Load());
    }

    [Fact]
    public void Unknown_schema_version_is_rejected()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(ConfigPath, """{ "schemaVersion": 99, "level": 50 }""");
        Assert.Throws<ConfigException>(() => new ConfigStore(ConfigPath).Load());
    }

    [Fact]
    public void Password_hash_with_too_few_iterations_in_file_is_rejected()
    {
        var store = new ConfigStore(ConfigPath);
        store.Save(new SteadyVolumeConfig { Password = PasswordHasher.Hash("password1", PasswordHasher.MinimumIterations) });
        File.WriteAllText(ConfigPath, File.ReadAllText(ConfigPath).Replace("210000", "1000"));
        File.Delete(store.BackupPath);

        Assert.Throws<ConfigException>(() => store.Load());
    }

    [Fact]
    public void After_write_hook_runs_for_config_and_backup()
    {
        var written = new List<string>();
        var store = new ConfigStore(ConfigPath, written.Add);
        store.Save(new SteadyVolumeConfig());
        store.Save(new SteadyVolumeConfig());

        Assert.Contains(store.FilePath, written);
        Assert.Contains(store.BackupPath, written);
    }

    [Fact]
    public void Per_device_levels_round_trip_exactly()
    {
        var store = new ConfigStore(ConfigPath);
        store.Save(new SteadyVolumeConfig
        {
            Locked = true,
            Mode = LockMode.CurrentLevels,
            DeviceLevels =
            [
                new DeviceLevel { Id = "{0.0.0.00000000}.{a}", Name = "Speakers", Scalar = 1.0f },
                new DeviceLevel { Id = "{0.0.0.00000000}.{b}", Name = "Sound Blaster AE-9", Scalar = 0.499846f },
            ],
        });

        var loaded = store.Load();
        Assert.Equal(LockMode.CurrentLevels, loaded.Mode);
        Assert.Equal(0.499846f, loaded.DeviceLevels.Single(d => d.Name == "Sound Blaster AE-9").Scalar);
        var json = JsonNode.Parse(File.ReadAllText(ConfigPath))!.AsObject();
        Assert.Equal("currentLevels", json["mode"]!.GetValue<string>());
        Assert.False(json["deviceLevels"]![0]!.AsObject().ContainsKey("percent")); // derived, not stored
    }

    [Fact]
    public void Older_config_without_mode_loads_as_uniform()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(ConfigPath, """{ "schemaVersion": 1, "locked": true, "level": 30 }""");
        var loaded = new ConfigStore(ConfigPath).Load();
        Assert.Equal(LockMode.Uniform, loaded.Mode);
        Assert.Empty(loaded.DeviceLevels);
    }

    [Theory]
    [InlineData(1.5f)]
    [InlineData(-0.1f)]
    [InlineData(float.NaN)]
    public void Device_level_outside_0_to_1_is_refused(float scalar)
    {
        var config = new SteadyVolumeConfig { DeviceLevels = [new DeviceLevel { Id = "a", Scalar = scalar }] };
        Assert.Throws<ConfigException>(() => new ConfigStore(ConfigPath).Save(config));
    }

    [Fact]
    public void Duplicate_or_empty_device_ids_are_refused()
    {
        var store = new ConfigStore(ConfigPath);
        Assert.Throws<ConfigException>(() => store.Save(new SteadyVolumeConfig
        {
            DeviceLevels = [new DeviceLevel { Id = "a", Scalar = 0.1f }, new DeviceLevel { Id = "a", Scalar = 0.2f }],
        }));
        Assert.Throws<ConfigException>(() => store.Save(new SteadyVolumeConfig
        {
            DeviceLevels = [new DeviceLevel { Id = " ", Scalar = 0.1f }],
        }));
    }

    [Fact]
    public void Clone_copies_device_levels_deeply()
    {
        var a = new SteadyVolumeConfig { DeviceLevels = [new DeviceLevel { Id = "x", Scalar = 0.3f }] };
        var b = a.Clone();
        b.DeviceLevels[0].Scalar = 0.9f;
        b.DeviceLevels.Add(new DeviceLevel { Id = "y", Scalar = 0.1f });
        Assert.Equal(0.3f, a.DeviceLevels[0].Scalar);
        Assert.Single(a.DeviceLevels);
    }

    [Fact]
    public void Clone_is_independent()
    {
        var a = new SteadyVolumeConfig { Level = 10 };
        var b = a.Clone();
        b.Level = 90;
        Assert.Equal(10, a.Level);
    }
}
