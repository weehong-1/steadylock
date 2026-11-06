using System.ComponentModel;
using System.Reflection;
using SteadyVolume.Cli;
using SteadyVolume.Core;
using SteadyVolume.Core.Ipc;
using SteadyVolume.Core.Platform.Windows;
using SteadyVolume.Core.Security;

if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("This build of steadyvol only runs on Windows.");
    return ExitCodes.Failure;
}

return await new CliApp().RunAsync(args);

internal static class ExitCodes
{
    public const int Ok = 0;
    public const int Failure = 1;
    public const int Usage = 2;
    public const int WrongPassword = 3;
    public const int LockedOut = 4;
    public const int ServiceUnavailable = 5;
}

[System.Runtime.Versioning.SupportedOSPlatform("windows")]
internal sealed class CliApp
{
    private const string Usage =
        """
        steadyvol - control the SteadyVolume service

        Usage:
          steadyvol status          Show lock state, levels, protection and service state
          steadyvol lock            Lock every output device at its current level  [password]
                                    (nothing is changed; devices plugged in later are
                                    held at the level they have when they appear)
          steadyvol lock LEVEL      Lock every output device at LEVEL (0-100)      [password]
          steadyvol unlock          Stop enforcing the volume                       [password]
          steadyvol passwd          Change the password                             [password]
          steadyvol unprotect       Remove tamper protection so you can uninstall   [password]
          steadyvol setup           Create the first password (also offered automatically)
          steadyvol version         Show the CLI version

        Passwords are always typed at a hidden prompt, never given as arguments.
        """;

    private string _pipeName = SteadyVolumeConstants.PipeName;
    private bool _devPipe;

    public async Task<int> RunAsync(string[] rawArgs)
    {
        var args = ExtractGlobalOptions(rawArgs);
        if (args is null)
            return ExitCodes.Usage;

        try
        {
            switch (args)
            {
                case [] or ["help" or "--help" or "-h" or "/?"]:
                    Console.WriteLine(Usage);
                    return args.Count == 0 ? ExitCodes.Usage : ExitCodes.Ok;
                case ["version" or "--version"]:
                    Console.WriteLine($"steadyvol {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3)}");
                    return ExitCodes.Ok;
                case ["status"]:
                    return await StatusAsync();
                case ["setup"]:
                    return await SetupCommandAsync();
                case ["lock"]:
                    return await PasswordCommandAsync(IpcCommand.Lock, null);
                case ["lock", var levelText]:
                    if (!int.TryParse(levelText, out var level) || !VolumeMath.IsValidLevel(level))
                    {
                        Console.Error.WriteLine("LEVEL must be a whole number from 0 to 100.");
                        return ExitCodes.Usage;
                    }

                    return await PasswordCommandAsync(IpcCommand.Lock, level);
                case ["unlock"]:
                    return await PasswordCommandAsync(IpcCommand.Unlock, null);
                case ["passwd"]:
                    return await PasswordCommandAsync(IpcCommand.ChangePassword, null);
                case ["unprotect"]:
                    return await PasswordCommandAsync(IpcCommand.Unprotect, null);
                default:
                    if (args.Any(a => a.StartsWith("--pass", StringComparison.OrdinalIgnoreCase) || a.StartsWith("-p", StringComparison.Ordinal)))
                        Console.Error.WriteLine("Passwords are never accepted as arguments; you will be prompted.");
                    Console.Error.WriteLine(Usage);
                    return ExitCodes.Usage;
            }
        }
        catch (ServiceUnavailableException ex)
        {
            Console.Error.WriteLine(ex.Message);
            Console.Error.WriteLine(DescribeServiceState());
            return ExitCodes.ServiceUnavailable;
        }
    }

    private List<string>? ExtractGlobalOptions(string[] rawArgs)
    {
        var args = new List<string>();
        for (var i = 0; i < rawArgs.Length; i++)
        {
            if (rawArgs[i] == "--pipe")
            {
                if (i + 1 >= rawArgs.Length)
                {
                    Console.Error.WriteLine("--pipe needs a pipe name.");
                    return null;
                }

                _pipeName = rawArgs[++i];
                _devPipe = !string.Equals(_pipeName, SteadyVolumeConstants.PipeName, StringComparison.OrdinalIgnoreCase);
                continue;
            }

            args.Add(rawArgs[i]);
        }

        if (_devPipe)
            Console.Error.WriteLine($"[dev] Using pipe '{_pipeName}'. The server identity check is skipped.");
        return args;
    }

    private ServiceClient Client => new(_pipeName, verifyServer: !_devPipe);

    private async Task<int> StatusAsync()
    {
        Console.WriteLine(DescribeServiceState());

        if (!_devPipe && SafeQueryService().State != ServiceRunState.Running)
            return ExitCodes.ServiceUnavailable;

        var response = await Client.SendAsync(new IpcRequest { Command = IpcCommand.Status });
        if (!response.Ok || response.Status is null)
            return Report(response);

        var s = response.Status;
        if (!s.Locked)
        {
            Console.WriteLine("  Lock:        unlocked");
        }
        else if (s.Mode == SteadyVolume.Core.Config.LockMode.CurrentLevels)
        {
            var devices = s.Devices ?? new List<DeviceStatus>();
            Console.WriteLine($"  Lock:        locked at current levels ({devices.Count} device(s); new devices keep their level)");
            foreach (var d in devices.OrderBy(d => d.Name ?? d.Id, StringComparer.CurrentCultureIgnoreCase))
                Console.WriteLine($"                 {d.Level,3}%  {d.Name ?? d.Id}");
        }
        else
        {
            Console.WriteLine($"  Lock:        locked at {s.Level}% on every output device");
        }
        Console.WriteLine($"  Protection:  {(s.Protected ? "on" : "off (service can be stopped and uninstalled)")}");
        Console.WriteLine($"  Password:    {(s.PasswordSet ? "set" : "not set (run 'steadyvol setup')")}");
        Console.WriteLine($"  Version:     {s.ServiceVersion}");
        return ExitCodes.Ok;
    }

    private async Task<int> SetupCommandAsync()
    {
        var status = await GetStatusAsync();
        if (status.PasswordSet)
        {
            Console.Error.WriteLine("A password already exists. Use 'steadyvol passwd' to change it.");
            return ExitCodes.Failure;
        }

        return await CreatePasswordAsync() is null ? ExitCodes.Failure : ExitCodes.Ok;
    }

    private async Task<int> PasswordCommandAsync(IpcCommand command, int? level)
    {
        var status = await GetStatusAsync();

        string password;
        if (!status.PasswordSet)
        {
            Console.WriteLine("No password has been set yet. Create one now.");
            var created = await CreatePasswordAsync();
            if (created is null)
                return ExitCodes.Failure;
            if (command == IpcCommand.ChangePassword)
                return ExitCodes.Ok;
            password = created;
        }
        else
        {
            password = ConsolePassword.Read(command == IpcCommand.ChangePassword ? "Current password: " : "Password: ");
        }

        string? newPassword = null;
        if (command == IpcCommand.ChangePassword)
        {
            newPassword = PromptNewPassword();
            if (newPassword is null)
                return ExitCodes.Failure;
        }

        var response = await Client.SendAsync(new IpcRequest
        {
            Command = command,
            Password = password,
            NewPassword = newPassword,
            Level = level,
        });
        return Report(response);
    }

    /// <summary>Returns the new password on success, null on failure.</summary>
    private async Task<string?> CreatePasswordAsync()
    {
        var password = PromptNewPassword();
        if (password is null)
            return null;

        var response = await Client.SendAsync(new IpcRequest { Command = IpcCommand.Setup, NewPassword = password });
        return Report(response) == ExitCodes.Ok ? password : null;
    }

    private static string? PromptNewPassword()
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var first = ConsolePassword.Read("New password: ");
            if (PasswordPolicy.Check(first) is { } problem)
            {
                Console.Error.WriteLine(problem);
                continue;
            }

            var second = ConsolePassword.Read("Repeat new password: ");
            if (first != second)
            {
                Console.Error.WriteLine("The passwords do not match.");
                continue;
            }

            return first;
        }

        Console.Error.WriteLine("Giving up.");
        return null;
    }

    private async Task<StatusInfo> GetStatusAsync()
    {
        var response = await Client.SendAsync(new IpcRequest { Command = IpcCommand.Status });
        if (!response.Ok || response.Status is null)
            throw new ServiceUnavailableException(response.Message ?? "The service did not return its status.");
        return response.Status;
    }

    private static int Report(IpcResponse response)
    {
        if (response.Ok)
        {
            if (!string.IsNullOrEmpty(response.Message))
                Console.WriteLine(response.Message);
            if (!string.IsNullOrEmpty(response.Warning))
                Console.Error.WriteLine("Warning: " + response.Warning);
            return ExitCodes.Ok;
        }

        switch (response.Error)
        {
            case IpcErrorCode.WrongPassword:
                Console.Error.WriteLine(response.AttemptsRemaining is { } left
                    ? $"Wrong password. {left} attempt(s) left before a {(int)LockoutTracker.LockoutDuration.TotalSeconds}-second lockout."
                    : "Wrong password.");
                return ExitCodes.WrongPassword;
            case IpcErrorCode.LockedOut:
                Console.Error.WriteLine(response.RetryAfterSeconds is { } wait
                    ? $"{response.Message} Password commands are refused for another {wait} s."
                    : response.Message);
                return ExitCodes.LockedOut;
            default:
                Console.Error.WriteLine(response.Message ?? $"The service refused the command ({response.Error}).");
                return ExitCodes.Failure;
        }
    }

    private string DescribeServiceState()
    {
        if (_devPipe)
            return "SteadyVolume (development pipe)";

        var status = SafeQueryService();
        var state = status.State switch
        {
            ServiceRunState.NotInstalled => "not installed",
            ServiceRunState.Running => $"running (PID {status.ProcessId})",
            ServiceRunState.Unknown => "unknown (could not query the service)",
            var other => other.ToString().ToLowerInvariant(),
        };
        return $"SteadyVolume\n  Service:     {state}";
    }

    private static ServiceStatusSnapshot SafeQueryService()
    {
        try
        {
            return ServiceControlNative.QueryStatus(SteadyVolumeConstants.ServiceName);
        }
        catch (Win32Exception)
        {
            return new ServiceStatusSnapshot(ServiceRunState.Unknown, 0);
        }
    }
}
