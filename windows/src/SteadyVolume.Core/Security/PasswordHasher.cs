using System.Security.Cryptography;
using System.Text;

namespace SteadyVolume.Core.Security;

/// <summary>PBKDF2-HMAC-SHA256 with a random per-password salt and constant-time comparison.</summary>
public static class PasswordHasher
{
    public const string AlgorithmName = "PBKDF2-SHA256";

    /// <summary>Hard floor. Stored hashes below this are rejected, so a tampered config cannot downgrade.</summary>
    public const int MinimumIterations = 210_000;

    /// <summary>Iterations used for new hashes (OWASP 2023 guidance for PBKDF2-HMAC-SHA256).</summary>
    public const int DefaultIterations = 600_000;

    public const int SaltSize = 16;
    public const int HashSize = 32;

    public static PasswordHash Hash(string password, int iterations = DefaultIterations)
    {
        ArgumentNullException.ThrowIfNull(password);
        if (iterations < MinimumIterations)
            throw new ArgumentOutOfRangeException(nameof(iterations), $"At least {MinimumIterations} iterations are required.");

        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var hash = Derive(password, salt, iterations);
        try
        {
            return new PasswordHash(AlgorithmName, iterations, Convert.ToBase64String(salt), Convert.ToBase64String(hash));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(hash);
        }
    }

    /// <summary>
    /// Returns true when <paramref name="password"/> matches. Throws <see cref="InvalidPasswordHashException"/>
    /// when the stored record itself is unusable (wrong algorithm, too few iterations, bad encoding).
    /// </summary>
    public static bool Verify(string? password, PasswordHash stored)
    {
        ArgumentNullException.ThrowIfNull(stored);
        stored.Validate();

        var salt = Convert.FromBase64String(stored.Salt);
        var expected = Convert.FromBase64String(stored.Hash);
        // Always run the full derivation, even for an empty password, so timing does not leak anything.
        var actual = Derive(password ?? string.Empty, salt, stored.Iterations);
        try
        {
            return CryptographicOperations.FixedTimeEquals(actual, expected);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(actual);
        }
    }

    private static byte[] Derive(string password, byte[] salt, int iterations)
    {
        // Normalise so the same visible password always produces the same bytes.
        var normalized = password.Normalize(NormalizationForm.FormC);
        var bytes = Encoding.UTF8.GetBytes(normalized);
        try
        {
            return Rfc2898DeriveBytes.Pbkdf2(bytes, salt, iterations, HashAlgorithmName.SHA256, HashSize);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}
