using System.Diagnostics;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Logging.EventLog;
using SteadyVolume.Core;
using SteadyVolume.Core.Config;
using SteadyVolume.Core.Control;
using SteadyVolume.Service;

if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("SteadyVolume.Service only runs on Windows.");
    return 2;
}

if (args is ["--probe", ..])
    return AudioProbe.Run(args[1..]);

if (args is ["--help" or "-h" or "/?"])
{
    Console.WriteLine(ServiceOptions.Usage);
    return 0;
}

if (!ServiceOptions.TryParse(args, out var options, out var error))
{
    Console.Error.WriteLine(error);
    Console.Error.WriteLine();
    Console.Error.WriteLine(ServiceOptions.Usage);
    return 2;
}

if (!options.DevMode && !WindowsServiceHelpers.IsWindowsService())
{
    Console.Error.WriteLine(ServiceOptions.Usage);
    return 2;
}

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = [],
    ApplicationName = SteadyVolumeConstants.ServiceName,
    ContentRootPath = AppContext.BaseDirectory,
});

builder.Services.AddWindowsService(o => o.ServiceName = SteadyVolumeConstants.ServiceName);
builder.Services.Configure<EventLogSettings>(s =>
{
    s.SourceName = SteadyVolumeConstants.EventLogSource;
    s.LogName = "Application";
});
builder.Logging.AddFilter<EventLogLoggerProvider>("SteadyVolume", LogLevel.Information);
builder.Logging.AddFilter<EventLogLoggerProvider>("Microsoft", LogLevel.Warning);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ITamperProtection>(_ => options.DevMode
    ? new NoTamperProtection()
    : new ServiceProtection(SteadyVolumeConstants.ServiceName));
builder.Services.AddSingleton(CreateProcessor);
builder.Services.AddSingleton<VolumeEnforcer>();
builder.Services.AddHostedService<EnforcementService>();
builder.Services.AddHostedService<PipeServer>();

try
{
    builder.Build().Run();
    return 0;
}
catch (Exception ex)
{
    // Exiting non-zero makes the SCM treat this as a failure and apply the restart recovery action.
    TryWriteEventLog("SteadyVolume failed to start or crashed: " + ex);
    Console.Error.WriteLine(ex);
    return 1;
}

static CommandProcessor CreateProcessor(IServiceProvider services)
{
    var options = services.GetRequiredService<ServiceOptions>();
    var logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("SteadyVolume.Control");

    Action<string>? afterWrite = null;
    if (!options.DevMode)
    {
        ConfigFileSecurity.SecureDirectory(Path.GetDirectoryName(options.ConfigPath)!);
        afterWrite = ConfigFileSecurity.SecureFile;
        try
        {
            ConfigFileSecurity.TakeOwnershipOfProgramFolder(AppContext.BaseDirectory);
        }
        catch (Exception ex)
        {
            // Not fatal: the folder DACL set by the installer already makes it read-only for administrators.
            logger.LogWarning(LogEvents.ProtectionError, ex, "Could not make SYSTEM the owner of {Folder}.", AppContext.BaseDirectory);
        }
    }

    var store = new ConfigStore(options.ConfigPath, afterWrite);
    SteadyVolumeConfig config;
    try
    {
        config = store.Load();
    }
    catch (ConfigException ex)
    {
        logger.LogError(LogEvents.ConfigError, ex,
            "The config file and its backup are unreadable. They were renamed with a .corrupt suffix and the service " +
            "started unlocked with no password. Run 'steadyvol setup' again.");
        Quarantine(store.FilePath);
        Quarantine(store.BackupPath);
        config = new SteadyVolumeConfig();
    }

    return new CommandProcessor(
        store,
        config,
        services.GetRequiredService<ITamperProtection>(),
        services.GetRequiredService<TimeProvider>(),
        logger,
        snapshots: services.GetRequiredService<VolumeEnforcer>());
}

static void Quarantine(string path)
{
    try
    {
        if (File.Exists(path))
            File.Move(path, $"{path}.corrupt-{DateTime.UtcNow:yyyyMMddHHmmss}");
    }
    catch
    {
        // Best effort; the next save overwrites it anyway.
    }
}

static void TryWriteEventLog(string message)
{
    try
    {
        if (OperatingSystem.IsWindows())
            EventLog.WriteEntry(SteadyVolumeConstants.EventLogSource, message, EventLogEntryType.Error, 9999);
    }
    catch
    {
        // Nothing more we can do.
    }
}
