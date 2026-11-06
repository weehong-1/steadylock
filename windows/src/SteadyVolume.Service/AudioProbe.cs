using System.Diagnostics;
using System.Runtime.Versioning;
using System.Security.Principal;
using System.Text;
using NAudio.CoreAudioApi;
using SteadyVolume.Core;

namespace SteadyVolume.Service;

/// <summary>
/// "--probe": proves that the current process (for example SYSTEM in session 0) can enumerate
/// output devices, read and set the master volume, and receive volume and device notifications.
/// It moves the default device by 1% and puts it back. Mute is only read, never set.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class AudioProbe
{
    public static int Run(string[] args)
    {
        var reportPath = args.Length > 0 ? args[0] : null;
        var report = new StringBuilder();
        void Line(string text)
        {
            report.AppendLine(text);
            Console.WriteLine(text);
        }

        Line($"SteadyVolume audio probe, {DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}");
        using (var identity = WindowsIdentity.GetCurrent())
            Line($"Account: {identity.Name}  Session: {Process.GetCurrentProcess().SessionId}  UserInteractive: {Environment.UserInteractive}");

        var passed = false;
        var thread = new Thread(() =>
        {
            try
            {
                passed = Probe(Line);
            }
            catch (Exception ex)
            {
                Line("FAIL  unexpected error: " + ex);
            }
        });
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        thread.Join();

        Line(passed ? "RESULT: PASS" : "RESULT: FAIL");
        if (reportPath is not null)
        {
            try
            {
                File.WriteAllText(reportPath, report.ToString());
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Could not write the report to {reportPath}: {ex.Message}");
            }
        }

        return passed ? 0 : 1;
    }

    private static bool Probe(Action<string> line)
    {
        var ok = true;
        void Check(bool condition, string what)
        {
            line((condition ? "PASS  " : "FAIL  ") + what);
            ok &= condition;
        }

        using var enumerator = new MMDeviceEnumerator();
        line("PASS  created MMDeviceEnumerator");

        using var deviceEvents = enumerator.CreateNotificationClient(useSynchronizationContext: false);
        line("PASS  registered for device notifications (IMMNotificationClient)");

        var count = 0;
        using (var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            foreach (var device in devices)
            {
                count++;
                var volume = device.AudioEndpointVolume;
                line($"      output: {device.FriendlyName}  volume {VolumeMath.ToPercent(volume.MasterVolumeLevelScalar)}%  muted {volume.Mute}");
            }
        }

        Check(count > 0, $"found {count} active output device(s)");
        if (count == 0)
            return false;

        if (!enumerator.TryGetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia, out var defaultDevice) || defaultDevice is null)
        {
            Check(false, "found a default output device");
            return false;
        }

        using (defaultDevice)
        {
            var endpoint = defaultDevice.AudioEndpointVolume;
            var originalScalar = endpoint.MasterVolumeLevelScalar;
            var originalMute = endpoint.Mute;
            var original = VolumeMath.ToPercent(originalScalar);
            var test = original >= 50 ? original - 1 : original + 1;

            using var notified = new ManualResetEventSlim(false);
            AudioEndpointVolumeNotificationDelegate handler = data =>
            {
                if (VolumeMath.ToPercent(data.MasterVolume) == test)
                    notified.Set();
            };
            endpoint.OnVolumeNotification += handler;
            try
            {
                endpoint.MasterVolumeLevelScalar = VolumeMath.ToScalar(test);
                var readBack = VolumeMath.ToPercent(endpoint.MasterVolumeLevelScalar);
                Check(readBack == test, $"set default device '{defaultDevice.FriendlyName}' from {original}% to {test}% (read back {readBack}%)");
                Check(notified.Wait(TimeSpan.FromSeconds(2)), "received the volume change notification");
            }
            finally
            {
                endpoint.OnVolumeNotification -= handler;
                endpoint.MasterVolumeLevelScalar = originalScalar;
            }

            var restored = VolumeMath.ToPercent(endpoint.MasterVolumeLevelScalar);
            Check(restored == original, $"restored the original level {original}% (read back {restored}%)");
            Check(endpoint.Mute == originalMute, "mute state unchanged");
        }

        return ok;
    }
}
