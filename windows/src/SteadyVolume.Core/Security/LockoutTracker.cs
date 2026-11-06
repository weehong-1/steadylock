namespace SteadyVolume.Core.Security;

/// <summary>
/// After <see cref="MaxAttempts"/> consecutive wrong passwords, every password command is refused
/// for <see cref="LockoutDuration"/>, even with the right password. State is exposed so the service
/// can persist it and a restart does not reset the counter.
/// </summary>
public sealed class LockoutTracker
{
    public const int MaxAttempts = 5;
    public static readonly TimeSpan LockoutDuration = TimeSpan.FromSeconds(30);

    private readonly TimeProvider _time;

    public LockoutTracker(TimeProvider time, int failedAttempts = 0, DateTimeOffset? lockoutUntil = null)
    {
        _time = time ?? throw new ArgumentNullException(nameof(time));
        FailedAttempts = Math.Clamp(failedAttempts, 0, MaxAttempts - 1);
        LockoutUntil = lockoutUntil;
        // A stored deadline further away than one lockout period means the clock moved or the
        // file was edited. Never lock out for longer than the documented 30 seconds.
        ClampDeadline();
    }

    public int FailedAttempts { get; private set; }

    public DateTimeOffset? LockoutUntil { get; private set; }

    public int AttemptsRemaining => MaxAttempts - FailedAttempts;

    public bool IsLockedOut(out TimeSpan remaining)
    {
        ClampDeadline();
        if (LockoutUntil is { } until)
        {
            var now = _time.GetUtcNow();
            if (now < until)
            {
                remaining = until - now;
                return true;
            }

            LockoutUntil = null;
        }

        remaining = TimeSpan.Zero;
        return false;
    }

    /// <summary>Records a wrong password. Returns true if this failure started a lockout.</summary>
    public bool RecordFailure()
    {
        FailedAttempts++;
        if (FailedAttempts < MaxAttempts)
            return false;

        FailedAttempts = 0;
        LockoutUntil = _time.GetUtcNow() + LockoutDuration;
        return true;
    }

    public void RecordSuccess()
    {
        FailedAttempts = 0;
        LockoutUntil = null;
    }

    private void ClampDeadline()
    {
        if (LockoutUntil is { } until)
        {
            var latest = _time.GetUtcNow() + LockoutDuration;
            if (until > latest)
                LockoutUntil = latest;
        }
    }
}
