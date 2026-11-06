namespace SteadyVolume.Core.Control;

/// <summary>
/// Keeps revert logging readable: the first revert for a key is logged straight away, further
/// reverts inside the window are counted, and the count is reported once the window has passed.
/// Not thread-safe; used only from the enforcement thread.
/// </summary>
public sealed class RevertLogThrottle
{
    private readonly TimeProvider _time;
    private readonly TimeSpan _window;
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    public RevertLogThrottle(TimeProvider time, TimeSpan window)
    {
        _time = time ?? throw new ArgumentNullException(nameof(time));
        if (window <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(window));
        _window = window;
    }

    /// <summary>
    /// Registers one revert. Returns the number of reverts to report now (this one plus any
    /// suppressed earlier), or null if it should be suppressed.
    /// </summary>
    public int? Register(string key)
    {
        var now = _time.GetUtcNow();
        if (!_entries.TryGetValue(key, out var entry) || now - entry.LastReported >= _window)
        {
            var count = (entry?.Suppressed ?? 0) + 1;
            _entries[key] = new Entry { LastReported = now };
            return count;
        }

        entry.Suppressed++;
        return null;
    }

    /// <summary>Returns and clears suppressed counts whose window has ended.</summary>
    public IReadOnlyList<(string Key, int Count)> DrainExpired()
    {
        var now = _time.GetUtcNow();
        List<(string, int)>? result = null;
        foreach (var (key, entry) in _entries)
        {
            if (entry.Suppressed > 0 && now - entry.LastReported >= _window)
            {
                (result ??= new()).Add((key, entry.Suppressed));
                entry.Suppressed = 0;
                entry.LastReported = now;
            }
        }

        return result ?? (IReadOnlyList<(string, int)>)Array.Empty<(string, int)>();
    }

    private sealed class Entry
    {
        public DateTimeOffset LastReported;
        public int Suppressed;
    }
}
