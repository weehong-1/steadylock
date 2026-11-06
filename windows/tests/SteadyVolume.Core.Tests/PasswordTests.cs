using SteadyVolume.Core.Security;

namespace SteadyVolume.Core.Tests;

public class PasswordHasherTests
{
    // Use the minimum allowed count to keep tests fast; production uses DefaultIterations.
    private const int Iterations = PasswordHasher.MinimumIterations;

    [Fact]
    public void Hash_then_verify_with_same_password_succeeds()
    {
        var hash = PasswordHasher.Hash("correct horse battery", Iterations);
        Assert.True(PasswordHasher.Verify("correct horse battery", hash));
    }

    [Theory]
    [InlineData("correct horse batterY")]
    [InlineData("correct horse battery ")]
    [InlineData("")]
    [InlineData(null)]
    public void Verify_with_wrong_password_fails(string? attempt)
    {
        var hash = PasswordHasher.Hash("correct horse battery", Iterations);
        Assert.False(PasswordHasher.Verify(attempt, hash));
    }

    [Fact]
    public void Hash_uses_pbkdf2_sha256_with_random_salt_and_32_byte_hash()
    {
        var a = PasswordHasher.Hash("same password", Iterations);
        var b = PasswordHasher.Hash("same password", Iterations);

        Assert.Equal("PBKDF2-SHA256", a.Algorithm);
        Assert.Equal(Iterations, a.Iterations);
        Assert.Equal(PasswordHasher.SaltSize, Convert.FromBase64String(a.Salt).Length);
        Assert.Equal(PasswordHasher.HashSize, Convert.FromBase64String(a.Hash).Length);
        Assert.NotEqual(a.Salt, b.Salt);
        Assert.NotEqual(a.Hash, b.Hash);
    }

    [Fact]
    public void Default_iterations_meet_the_required_minimum()
    {
        Assert.True(PasswordHasher.DefaultIterations >= 210_000);
        Assert.True(PasswordHasher.MinimumIterations >= 210_000);
    }

    [Fact]
    public void Hash_refuses_fewer_than_minimum_iterations()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => PasswordHasher.Hash("password1", PasswordHasher.MinimumIterations - 1));
    }

    [Fact]
    public void Verify_rejects_a_stored_hash_downgraded_below_minimum_iterations()
    {
        var hash = PasswordHasher.Hash("password1", Iterations) with { Iterations = 1000 };
        Assert.Throws<InvalidPasswordHashException>(() => PasswordHasher.Verify("password1", hash));
    }

    [Fact]
    public void Verify_rejects_unknown_algorithm_and_bad_encoding()
    {
        var hash = PasswordHasher.Hash("password1", Iterations);
        Assert.Throws<InvalidPasswordHashException>(() => PasswordHasher.Verify("password1", hash with { Algorithm = "MD5" }));
        Assert.Throws<InvalidPasswordHashException>(() => PasswordHasher.Verify("password1", hash with { Salt = "not base64!" }));
        Assert.Throws<InvalidPasswordHashException>(() => PasswordHasher.Verify("password1", hash with { Hash = Convert.ToBase64String(new byte[5]) }));
    }

    [Fact]
    public void Unicode_composed_and_decomposed_forms_are_equivalent()
    {
        var composed = "café-password";
        var decomposed = "café-password";
        var hash = PasswordHasher.Hash(composed, Iterations);
        Assert.True(PasswordHasher.Verify(decomposed, hash));
    }
}

public class PasswordPolicyTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("short")]
    [InlineData("        ")]
    [InlineData("has\ttab chars")]
    public void Rejects_bad_passwords(string? password) => Assert.NotNull(PasswordPolicy.Check(password));

    [Theory]
    [InlineData("eight ch")]
    [InlineData("a much longer pass phrase")]
    [InlineData("ünïcødé-ok")]
    public void Accepts_reasonable_passwords(string password) => Assert.Null(PasswordPolicy.Check(password));

    [Fact]
    public void Rejects_overlong_passwords() =>
        Assert.NotNull(PasswordPolicy.Check(new string('x', PasswordPolicy.MaximumLength + 1)));
}
