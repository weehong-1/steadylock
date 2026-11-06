namespace SteadyVolume.Core.Security;

public static class PasswordPolicy
{
    public const int MinimumLength = 8;
    public const int MaximumLength = 256;

    /// <summary>Returns null when the password is acceptable, otherwise a message for the user.</summary>
    public static string? Check(string? password)
    {
        if (string.IsNullOrEmpty(password))
            return "The password cannot be empty.";
        if (password.Length < MinimumLength)
            return $"The password must be at least {MinimumLength} characters.";
        if (password.Length > MaximumLength)
            return $"The password must be at most {MaximumLength} characters.";
        if (password.Any(char.IsControl))
            return "The password cannot contain control characters.";
        if (string.IsNullOrWhiteSpace(password))
            return "The password cannot be only spaces.";
        return null;
    }
}
