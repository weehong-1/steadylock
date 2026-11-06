namespace SteadyVolume.Core;

/// <summary>Names and paths shared by the service, the CLI and the install scripts.</summary>
public static class SteadyVolumeConstants
{
    public const string ServiceName = "SteadyVolume";
    public const string PipeName = "SteadyVolume";
    public const string EventLogSource = "SteadyVolume";

    public static string ConfigDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SteadyVolume");

    public static string ConfigPath => Path.Combine(ConfigDirectory, "config.json");
}
