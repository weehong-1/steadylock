using System.Collections.Concurrent;
using System.Runtime.Versioning;
using NAudio.CoreAudioApi;
using SteadyVolume.Core;
using SteadyVolume.Core.Config;
using SteadyVolume.Core.Control;

namespace SteadyVolume.Service;

/// <summary>
/// Owns every Core Audio object on one dedicated MTA thread. OS callbacks (volume changes and
/// device add/remove/default changes) never touch the audio API; they only set flags and signal
/// this thread. The thread also wakes every 250 ms as a backup in case a notification is missed.
/// Requests to read the current levels (for "lock at current levels") are also served on this thread.
/// Only the master volume scalar of active render endpoints is read or written. Mute, per-app
/// session volumes and capture devices are never touched.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class VolumeEnforcer : IVolumeSnapshotProvider, IDisposable
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan RevertLogWindow = TimeSpan.FromSeconds(10);

    private readonly ILogger<VolumeEnforcer> _logger;
    private readonly bool _dryRun;
    private readonly RevertLogThrottle _revertLog;
    private readonly RevertLogThrottle _errorLog;
    private readonly AutoResetEvent _signal = new(false);
    private readonly ManualResetEvent _stop = new(false);
    private readonly AudioEndpointVolumeNotificationDelegate _onVolumeChanged;
    private readonly List<Endpoint> _endpoints = new();
    private readonly Dictionary<string, string> _deviceNames = new(StringComparer.Ordinal);
    private readonly ConcurrentQueue<TaskCompletionSource<IReadOnlyList<DeviceLevel>>> _captureRequests = new();

    // Enforcement-thread only: devices first seen while locked at current levels, held at the level
    // they reported then. Cleared whenever a new target arrives (it already includes persisted ones).
    private readonly Dictionary<string, float> _adopted = new(StringComparer.Ordinal);
    private EnforcementTarget? _appliedTarget;

    private Thread? _thread;
    private volatile EnforcementTarget? _target; // null = unlocked
    private volatile bool _devicesDirty = true;
    private MMDeviceEnumerator? _enumerator;
    private MMDeviceNotificationClient? _deviceNotifications;
    private HashSet<string> _lastDeviceIds = new(StringComparer.Ordinal);

    public VolumeEnforcer(ILogger<VolumeEnforcer> logger, ServiceOptions options, TimeProvider time)
    {
        _logger = logger;
        _dryRun = options.DryRun;
        _revertLog = new RevertLogThrottle(time, RevertLogWindow);
        _errorLog = new RevertLogThrottle(time, TimeSpan.FromMinutes(1));
        _onVolumeChanged = _ => _signal.Set();
    }

    /// <summary>
    /// Raised on a thread-pool thread (never the enforcement thread) when a device not covered by a
    /// current-levels lock was seen and is now held at the level it reported.
    /// </summary>
    public event Action<DeviceLevel>? DeviceDiscovered;

    /// <summary>Thread-safe. Null stops enforcement without touching the volume.</summary>
    public void SetTarget(EnforcementTarget? target)
    {
        _target = target;
        _signal.Set();
    }

    /// <summary>Thread-safe; read-only. Served by the enforcement thread, which owns the audio objects.</summary>
    public IReadOnlyList<DeviceLevel> CaptureCurrentLevels(TimeSpan timeout)
    {
        if (Thread.CurrentThread == _thread)
            throw new InvalidOperationException("Cannot capture levels from the enforcement thread.");
        var request = new TaskCompletionSource<IReadOnlyList<DeviceLevel>>(TaskCreationOptions.RunContinuationsAsynchronously);
        _captureRequests.Enqueue(request);
        _signal.Set();
        try
        {
            return request.Task.WaitAsync(timeout).GetAwaiter().GetResult();
        }
        catch (TimeoutException)
        {
            throw new TimeoutException("The audio system did not answer in time.");
        }
    }

    public void Start()
    {
        if (_thread is not null)
            throw new InvalidOperationException("Already started.");
        _thread = new Thread(Run) { IsBackground = true, Name = "SteadyVolume enforcer" };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    public void Stop()
    {
        _stop.Set();
        _thread?.Join(TimeSpan.FromSeconds(5));
        while (_captureRequests.TryDequeue(out var pending))
            pending.TrySetException(new OperationCanceledException("The service is stopping."));
    }

    public void Dispose()
    {
        Stop();
        _signal.Dispose();
        _stop.Dispose();
    }

    // ---- callbacks: signal only ---------------------------------------------------------------

    private void MarkDevicesDirty()
    {
        _devicesDirty = true;
        _signal.Set();
    }

    // ---- enforcement thread -------------------------------------------------------------------

    private void Run()
    {
        var handles = new WaitHandle[] { _stop, _signal };
        while (!_stop.WaitOne(0))
        {
            try
            {
                RunSession(handles);
            }
            catch (Exception ex)
            {
                if (_errorLog.Register("session") is not null)
                    _logger.LogError(LogEvents.AudioError, ex,
                        "Audio enforcement error. Reconnecting to the audio system in {Seconds} s.", RetryDelay.TotalSeconds);
            }
            finally
            {
                Teardown();
            }

            if (_stop.WaitOne(RetryDelay))
                break;
        }
    }

    private void RunSession(WaitHandle[] handles)
    {
        _enumerator = new MMDeviceEnumerator();
        _deviceNotifications = _enumerator.CreateNotificationClient(useSynchronizationContext: false);
        _deviceNotifications.DeviceAdded += delegate { MarkDevicesDirty(); };
        _deviceNotifications.DeviceRemoved += delegate { MarkDevicesDirty(); };
        _deviceNotifications.DeviceStateChanged += delegate { MarkDevicesDirty(); };
        _deviceNotifications.DefaultDeviceChanged += delegate { MarkDevicesDirty(); };
        _devicesDirty = true;

        while (true)
        {
            if (_devicesDirty)
                RebuildEndpoints();

            ServeCaptureRequests();
            EnforceAll();
            ReportSuppressedReverts();

            if (WaitHandle.WaitAny(handles, PollInterval) == 0)
                return;
        }
    }

    private void RebuildEndpoints()
    {
        _devicesDirty = false; // cleared first so a change during enumeration marks it dirty again
        ReleaseEndpoints();

        var ids = new List<string>();
        using (var collection = _enumerator!.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            foreach (var device in collection)
                ids.Add(device.ID);
        }

        foreach (var id in ids)
        {
            MMDevice? device = null;
            try
            {
                device = _enumerator.GetDevice(id);
                var volume = device.AudioEndpointVolume;
                volume.OnVolumeNotification += _onVolumeChanged;
                var friendlyName = SafeFriendlyName(device);
                _deviceNames[id] = friendlyName ?? id;
                _endpoints.Add(new Endpoint(id, friendlyName, device, volume));
            }
            catch (Exception ex)
            {
                device?.Dispose();
                // Device vanished between enumeration and open; the next notification or poll retries.
                _devicesDirty = true;
                if (_errorLog.Register("open:" + id) is not null)
                    _logger.LogWarning(LogEvents.AudioError, ex, "Could not open output device {DeviceId}.", id);
            }
        }

        var currentIds = _endpoints.Select(e => e.Id).ToHashSet(StringComparer.Ordinal);
        if (!currentIds.SetEquals(_lastDeviceIds))
        {
            _lastDeviceIds = currentIds;
            _logger.LogInformation(LogEvents.DevicesChanged, "Watching {Count} active output device(s): {Devices}.",
                _endpoints.Count, string.Join(", ", _endpoints.Select(e => e.Name)));
        }
    }

    private void ServeCaptureRequests()
    {
        while (_captureRequests.TryDequeue(out var request))
        {
            try
            {
                var levels = _endpoints
                    .Select(e => new DeviceLevel
                    {
                        Id = e.Id,
                        Name = e.FriendlyName,
                        Scalar = Math.Clamp(e.Volume.MasterVolumeLevelScalar, 0f, 1f),
                    })
                    .ToList();
                request.TrySetResult(levels);
            }
            catch (Exception ex)
            {
                _devicesDirty = true;
                request.TrySetException(ex);
            }
        }
    }

    private void EnforceAll()
    {
        var target = _target;
        if (!ReferenceEquals(target, _appliedTarget))
        {
            _adopted.Clear();
            _appliedTarget = target;
        }

        if (target is null)
            return;

        foreach (var endpoint in _endpoints)
        {
            try
            {
                Enforce(endpoint, target);
            }
            catch (Exception ex)
            {
                // Usually AUDCLNT_E_DEVICE_INVALIDATED after an unplug. Rebuild on the next pass;
                // if the whole audio service is gone the rebuild throws and the session restarts.
                _devicesDirty = true;
                if (_errorLog.Register("enforce:" + endpoint.Id) is not null)
                    _logger.LogWarning(LogEvents.AudioError, ex, "Could not enforce volume on {Device}.", endpoint.Name);
            }
        }
    }

    private void Enforce(Endpoint endpoint, EnforcementTarget target)
    {
        var currentScalar = endpoint.Volume.MasterVolumeLevelScalar;
        var expectedScalar = target.ScalarFor(endpoint.Id);

        if (expectedScalar is null)
        {
            if (!target.CaptureNewDevices)
                return;
            if (!_adopted.TryGetValue(endpoint.Id, out var adopted))
            {
                // First time this device is seen under a current-levels lock: hold it where it is. No write.
                adopted = Math.Clamp(currentScalar, 0f, 1f);
                _adopted[endpoint.Id] = adopted;
                var discovered = new DeviceLevel { Id = endpoint.Id, Name = endpoint.FriendlyName, Scalar = adopted };
                RaiseDeviceDiscovered(discovered);
                return;
            }

            expectedScalar = adopted;
        }

        var current = VolumeMath.ToPercent(currentScalar);
        var expected = VolumeMath.ToPercent(expectedScalar.Value);
        if (current == expected || endpoint.IsAcceptedSubstitute(expected, current))
            return;

        if (_dryRun)
        {
            LogRevert(endpoint, current, expected, dryRun: true);
            return;
        }

        // Write back the exact stored scalar (for example 0.4998), not a rounded percent.
        endpoint.Volume.MasterVolumeLevelScalar = expectedScalar.Value;

        // Some hardware volume controls only support coarse steps. If the device cannot land on the
        // exact percent, accept the closest value it reports, otherwise we would rewrite it forever.
        var after = VolumeMath.ToPercent(endpoint.Volume.MasterVolumeLevelScalar);
        if (after != expected)
            endpoint.AcceptSubstitute(expected, after);

        LogRevert(endpoint, current, expected, dryRun: false);
    }

    private void RaiseDeviceDiscovered(DeviceLevel device)
    {
        var handler = DeviceDiscovered;
        if (handler is null)
            return;
        // Never call out from the enforcement thread: the handler takes the control lock and saves the config.
        ThreadPool.QueueUserWorkItem(_ =>
        {
            try
            {
                handler(device);
            }
            catch (Exception ex)
            {
                _logger.LogError(LogEvents.ConfigError, ex, "Could not record new device {Device}.", device.Name ?? device.Id);
            }
        });
    }

    private void LogRevert(Endpoint endpoint, int from, int to, bool dryRun)
    {
        if (_revertLog.Register(endpoint.Id) is not { } count)
            return;

        var verb = dryRun ? "Would revert (dry run)" : "Reverted";
        if (count == 1)
            _logger.LogInformation(LogEvents.VolumeReverted, "{Verb} master volume on {Device} from {From}% to {To}%.",
                verb, endpoint.Name, from, to);
        else
            _logger.LogInformation(LogEvents.VolumeReverted,
                "{Verb} master volume on {Device} from {From}% to {To}% ({Count} changes since the last report).",
                verb, endpoint.Name, from, to, count);
    }

    private void ReportSuppressedReverts()
    {
        foreach (var (id, count) in _revertLog.DrainExpired())
        {
            var name = _deviceNames.GetValueOrDefault(id, id);
            _logger.LogInformation(LogEvents.VolumeReverted,
                "Reverted master volume on {Device} {Count} more time(s) in the last {Seconds} s.",
                name, count, RevertLogWindow.TotalSeconds);
        }
    }

    private void ReleaseEndpoints()
    {
        foreach (var endpoint in _endpoints)
        {
            try { endpoint.Volume.OnVolumeNotification -= _onVolumeChanged; } catch { /* already gone */ }
            try { endpoint.Device.Dispose(); } catch { /* already gone */ }
        }

        _endpoints.Clear();
    }

    private void Teardown()
    {
        ReleaseEndpoints();
        try { _deviceNotifications?.Dispose(); } catch { /* audio service gone */ }
        try { _enumerator?.Dispose(); } catch { /* audio service gone */ }
        _deviceNotifications = null;
        _enumerator = null;
        _lastDeviceIds = new HashSet<string>(StringComparer.Ordinal);
    }

    private static string? SafeFriendlyName(MMDevice device)
    {
        try
        {
            return device.FriendlyName;
        }
        catch
        {
            return null;
        }
    }

    private sealed class Endpoint(string id, string? friendlyName, MMDevice device, AudioEndpointVolume volume)
    {
        private int _substituteFor = -1;
        private int _substitute = -1;

        public string Id { get; } = id;
        public string? FriendlyName { get; } = friendlyName;
        public string Name { get; } = friendlyName is null ? id : $"'{friendlyName}'";
        public MMDevice Device { get; } = device;
        public AudioEndpointVolume Volume { get; } = volume;

        public bool IsAcceptedSubstitute(int target, int current) => _substituteFor == target && _substitute == current;

        public void AcceptSubstitute(int target, int actual)
        {
            _substituteFor = target;
            _substitute = actual;
        }
    }
}
