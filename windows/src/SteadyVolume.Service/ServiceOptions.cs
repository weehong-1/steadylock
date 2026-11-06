using SteadyVolume.Core;

namespace SteadyVolume.Service;

/// <summary>
/// Normal service runs take no arguments. <c>--dev</c> runs in a console for development:
/// separate config and pipe, no tamper protection, no ACL changes, and volume writes are
/// logged instead of performed unless <c>--enforce</c> is given.
/// </summary>
internal sealed record ServiceOptions(bool DevMode, string ConfigPath, string PipeName, bool DryRun)
{
    public static ServiceOptions Production { get; } =
        new(false, SteadyVolumeConstants.ConfigPath, SteadyVolumeConstants.PipeName, false);

    public const string Usage =
        """
        steadyvolume-service: the SteadyVolume Windows service.

        It is normally started by the Service Control Manager with no arguments.

        Development and diagnostics:
          --dev [--config PATH] [--pipe NAME] [--enforce]
              Run in this console with a separate config file and pipe name.
              Tamper protection and ACL changes are skipped. Volume changes are only
              logged unless --enforce is given.
          --probe [REPORT_PATH]
              Check that this process can read, set and observe the master volume.
              Nudges the default device by 1% and restores it. Writes a report.
        """;

    public static bool TryParse(string[] args, out ServiceOptions options, out string? error)
    {
        options = Production;
        error = null;
        if (args.Length == 0)
            return true;

        var dev = false;
        var enforce = false;
        string? config = null;
        string? pipe = null;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--dev":
                    dev = true;
                    break;
                case "--enforce":
                    enforce = true;
                    break;
                case "--config" when i + 1 < args.Length:
                    config = args[++i];
                    break;
                case "--pipe" when i + 1 < args.Length:
                    pipe = args[++i];
                    break;
                default:
                    error = $"Unknown or incomplete argument '{args[i]}'.";
                    return false;
            }
        }

        if (!dev)
        {
            error = "--config, --pipe and --enforce are only valid together with --dev.";
            return false;
        }

        if (pipe is not null && string.Equals(pipe, SteadyVolumeConstants.PipeName, StringComparison.OrdinalIgnoreCase))
        {
            error = "Development mode must not use the production pipe name.";
            return false;
        }

        config ??= Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SteadyVolume-dev", "config.json");
        options = new ServiceOptions(true, Path.GetFullPath(config), pipe ?? "SteadyVolume-dev", DryRun: !enforce);
        return true;
    }
}
