using System.Text.Json;
using System.Text.Json.Serialization;

namespace SteadyVolume.Core.Config;

public interface IConfigStore
{
    SteadyVolumeConfig Load();
    void Save(SteadyVolumeConfig config);
}

/// <summary>
/// JSON file store. Writes go to a temp file first and are then swapped in atomically,
/// keeping the previous version as <c>config.json.bak</c>. If the main file is unreadable,
/// the backup is used.
/// </summary>
public sealed class ConfigStore : IConfigStore
{
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly Action<string>? _afterWrite;

    /// <param name="path">Full path of config.json.</param>
    /// <param name="afterWrite">Optional hook run on each file written (used to re-apply ACLs).</param>
    public ConfigStore(string path, Action<string>? afterWrite = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        FilePath = Path.GetFullPath(path);
        _afterWrite = afterWrite;
    }

    public string FilePath { get; }

    public string BackupPath => FilePath + ".bak";

    private string TempPath => FilePath + ".tmp";

    /// <summary>
    /// Returns defaults when no file exists. Throws <see cref="ConfigException"/> when both the
    /// file and its backup exist but neither can be read.
    /// </summary>
    public SteadyVolumeConfig Load()
    {
        var mainExists = File.Exists(FilePath);
        var backupExists = File.Exists(BackupPath);
        if (!mainExists && !backupExists)
            return new SteadyVolumeConfig();

        Exception? mainError = null;
        if (mainExists)
        {
            try
            {
                return ReadFile(FilePath);
            }
            catch (Exception ex) when (IsReadError(ex))
            {
                mainError = ex;
            }
        }

        if (backupExists)
        {
            try
            {
                return ReadFile(BackupPath);
            }
            catch (Exception ex) when (IsReadError(ex))
            {
                throw new ConfigException("Both config.json and its backup are unreadable.", mainError ?? ex);
            }
        }

        throw new ConfigException("config.json is unreadable and there is no backup.", mainError!);
    }

    public void Save(SteadyVolumeConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);
        config.Validate();

        var directory = Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(directory);

        using (var stream = new FileStream(TempPath, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            JsonSerializer.Serialize(stream, config, JsonOptions);
            stream.Flush(flushToDisk: true);
        }

        if (File.Exists(FilePath))
            File.Replace(TempPath, FilePath, BackupPath, ignoreMetadataErrors: true);
        else
            File.Move(TempPath, FilePath);

        if (_afterWrite is not null)
        {
            _afterWrite(FilePath);
            if (File.Exists(BackupPath))
                _afterWrite(BackupPath);
        }
    }

    private static SteadyVolumeConfig ReadFile(string path)
    {
        var bytes = File.ReadAllBytes(path);
        var config = JsonSerializer.Deserialize<SteadyVolumeConfig>(bytes, JsonOptions)
                     ?? throw new ConfigException($"{Path.GetFileName(path)} is empty.");
        config.Validate();
        return config;
    }

    private static bool IsReadError(Exception ex) =>
        ex is JsonException or ConfigException or IOException or UnauthorizedAccessException or NotSupportedException;
}
