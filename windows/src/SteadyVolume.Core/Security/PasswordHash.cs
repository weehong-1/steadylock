namespace SteadyVolume.Core.Security;

/// <summary>A stored PBKDF2 password hash. Salt and hash are Base64.</summary>
public sealed record PasswordHash(string Algorithm, int Iterations, string Salt, string Hash)
{
    /// <summary>Throws <see cref="InvalidPasswordHashException"/> if this record is not usable.</summary>
    public void Validate()
    {
        if (Algorithm != PasswordHasher.AlgorithmName)
            throw new InvalidPasswordHashException($"Unsupported password algorithm '{Algorithm}'.");
        if (Iterations < PasswordHasher.MinimumIterations)
            throw new InvalidPasswordHashException(
                $"Stored iteration count {Iterations} is below the minimum of {PasswordHasher.MinimumIterations}.");

        var salt = DecodeOrThrow(Salt, "salt");
        if (salt.Length < PasswordHasher.SaltSize)
            throw new InvalidPasswordHashException("Stored salt is too short.");

        var hash = DecodeOrThrow(Hash, "hash");
        if (hash.Length != PasswordHasher.HashSize)
            throw new InvalidPasswordHashException("Stored hash has the wrong length.");
    }

    private static byte[] DecodeOrThrow(string value, string what)
    {
        try
        {
            return Convert.FromBase64String(value ?? string.Empty);
        }
        catch (FormatException ex)
        {
            throw new InvalidPasswordHashException($"Stored {what} is not valid Base64.", ex);
        }
    }
}

public sealed class InvalidPasswordHashException : Exception
{
    public InvalidPasswordHashException(string message) : base(message) { }
    public InvalidPasswordHashException(string message, Exception inner) : base(message, inner) { }
}
