using Microsoft.Extensions.Time.Testing;
using SteadyVolume.Core.Security;

namespace SteadyVolume.Core.Tests;

public class LockoutTrackerTests
{
    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero));

    [Fact]
    public void Four_failures_do_not_lock_out()
    {
        var tracker = new LockoutTracker(_time);
        for (var i = 0; i < 4; i++)
            Assert.False(tracker.RecordFailure());

        Assert.False(tracker.IsLockedOut(out _));
        Assert.Equal(1, tracker.AttemptsRemaining);
    }

    [Fact]
    public void Fifth_failure_locks_out_for_30_seconds()
    {
        var tracker = new LockoutTracker(_time);
        for (var i = 0; i < 4; i++)
            tracker.RecordFailure();

        Assert.True(tracker.RecordFailure());
        Assert.True(tracker.IsLockedOut(out var remaining));
        Assert.Equal(TimeSpan.FromSeconds(30), remaining);

        _time.Advance(TimeSpan.FromSeconds(29));
        Assert.True(tracker.IsLockedOut(out remaining));
        Assert.Equal(TimeSpan.FromSeconds(1), remaining);

        _time.Advance(TimeSpan.FromSeconds(1));
        Assert.False(tracker.IsLockedOut(out _));
        Assert.Null(tracker.LockoutUntil);
    }

    [Fact]
    public void Counter_restarts_after_a_lockout_ends()
    {
        var tracker = new LockoutTracker(_time);
        for (var i = 0; i < 5; i++)
            tracker.RecordFailure();
        _time.Advance(TimeSpan.FromSeconds(31));

        Assert.False(tracker.IsLockedOut(out _));
        Assert.Equal(LockoutTracker.MaxAttempts, tracker.AttemptsRemaining);
    }

    [Fact]
    public void Success_resets_the_counter()
    {
        var tracker = new LockoutTracker(_time);
        for (var i = 0; i < 4; i++)
            tracker.RecordFailure();

        tracker.RecordSuccess();
        Assert.Equal(0, tracker.FailedAttempts);
        Assert.False(tracker.RecordFailure());
    }

    [Fact]
    public void Persisted_state_survives_a_restart()
    {
        var first = new LockoutTracker(_time);
        for (var i = 0; i < 5; i++)
            first.RecordFailure();

        _time.Advance(TimeSpan.FromSeconds(10));
        var restarted = new LockoutTracker(_time, first.FailedAttempts, first.LockoutUntil);
        Assert.True(restarted.IsLockedOut(out var remaining));
        Assert.Equal(TimeSpan.FromSeconds(20), remaining);
    }

    [Fact]
    public void Persisted_failure_count_carries_over()
    {
        var restarted = new LockoutTracker(_time, failedAttempts: 4);
        Assert.True(restarted.RecordFailure());
    }

    [Fact]
    public void A_deadline_far_in_the_future_is_capped_at_30_seconds()
    {
        var tracker = new LockoutTracker(_time, 0, _time.GetUtcNow().AddDays(365));
        Assert.True(tracker.IsLockedOut(out var remaining));
        Assert.Equal(TimeSpan.FromSeconds(30), remaining);
    }
}
