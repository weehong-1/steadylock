namespace SteadyVolume.Core;

/// <summary>
/// Converts between the 0.0-1.0 scalar used by the OS audio APIs and whole percents.
/// All comparisons are done on rounded whole percents so tiny float differences never
/// cause a write (and therefore never cause a notification feedback loop).
/// </summary>
public static class VolumeMath
{
    public const int MinLevel = 0;
    public const int MaxLevel = 100;

    public static bool IsValidLevel(int level) => level is >= MinLevel and <= MaxLevel;

    public static int ToPercent(float scalar)
    {
        if (float.IsNaN(scalar)) return 0;
        var clamped = Math.Clamp(scalar, 0f, 1f);
        return (int)Math.Round(clamped * 100.0, MidpointRounding.AwayFromZero);
    }

    public static float ToScalar(int percent)
    {
        if (!IsValidLevel(percent)) throw new ArgumentOutOfRangeException(nameof(percent));
        return percent / 100f;
    }
}
