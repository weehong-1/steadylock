using System.Buffers.Binary;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Time.Testing;
using SteadyVolume.Core.Control;
using SteadyVolume.Core.Ipc;

namespace SteadyVolume.Core.Tests;

public class IpcFramingTests
{
    [Fact]
    public async Task Request_round_trips_through_a_stream()
    {
        using var stream = new MemoryStream();
        await IpcFraming.WriteAsync(stream, new IpcRequest { Command = IpcCommand.Lock, Level = 42, Password = "pw" }, default);
        stream.Position = 0;

        var read = await IpcFraming.ReadAsync<IpcRequest>(stream, default);
        Assert.Equal(IpcCommand.Lock, read.Command);
        Assert.Equal(42, read.Level);
        Assert.Equal("pw", read.Password);
    }

    [Fact]
    public async Task Wire_format_is_little_endian_length_plus_camelCase_json()
    {
        // The macOS implementation depends on exactly this shape.
        using var stream = new MemoryStream();
        await IpcFraming.WriteAsync(stream, new IpcRequest { Command = IpcCommand.ChangePassword, NewPassword = "x" }, default);
        var bytes = stream.ToArray();

        var length = BinaryPrimitives.ReadInt32LittleEndian(bytes);
        Assert.Equal(bytes.Length - 4, length);
        var json = JsonNode.Parse(Encoding.UTF8.GetString(bytes, 4, length))!.AsObject();
        Assert.Equal("changePassword", json["command"]!.GetValue<string>());
        Assert.Equal(1, json["protocolVersion"]!.GetValue<int>());
        Assert.Equal("x", json["newPassword"]!.GetValue<string>());
        Assert.False(json.ContainsKey("password")); // nulls omitted
    }

    [Fact]
    public async Task Lock_at_current_levels_is_a_lock_request_without_a_level()
    {
        using var stream = new MemoryStream();
        await IpcFraming.WriteAsync(stream, new IpcRequest { Command = IpcCommand.Lock, Password = "pw" }, default);
        var json = JsonNode.Parse(Encoding.UTF8.GetString(stream.ToArray(), 4, (int)stream.Length - 4))!.AsObject();
        Assert.Equal("lock", json["command"]!.GetValue<string>());
        Assert.False(json.ContainsKey("level"));
    }

    [Fact]
    public async Task Error_codes_serialise_as_camelCase_strings()
    {
        using var stream = new MemoryStream();
        await IpcFraming.WriteAsync(stream, IpcResponse.Failure(IpcErrorCode.LockedOut, "wait"), default);
        var json = JsonNode.Parse(Encoding.UTF8.GetString(stream.ToArray(), 4, (int)stream.Length - 4))!;
        Assert.Equal("lockedOut", json["error"]!.GetValue<string>());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-5)]
    [InlineData(IpcFraming.MaxMessageBytes + 1)]
    public async Task Invalid_length_prefix_is_rejected(int length)
    {
        var header = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(header, length);
        using var stream = new MemoryStream(header);
        await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadAsync<IpcRequest>(stream, default));
    }

    [Fact]
    public async Task Truncated_message_is_rejected()
    {
        var bytes = new byte[4 + 3];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, 50);
        using var stream = new MemoryStream(bytes);
        await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadAsync<IpcRequest>(stream, default));
    }

    [Fact]
    public async Task Malformed_json_and_numeric_enums_are_rejected()
    {
        foreach (var body in new[] { "{nope", """{"command": 2}""" })
        {
            var payload = Encoding.UTF8.GetBytes(body);
            var bytes = new byte[4 + payload.Length];
            BinaryPrimitives.WriteInt32LittleEndian(bytes, payload.Length);
            payload.CopyTo(bytes, 4);
            using var stream = new MemoryStream(bytes);
            await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadAsync<IpcRequest>(stream, default));
        }
    }
}

public class VolumeMathTests
{
    [Fact]
    public void Every_whole_percent_survives_a_round_trip()
    {
        for (var p = 0; p <= 100; p++)
            Assert.Equal(p, VolumeMath.ToPercent(VolumeMath.ToScalar(p)));
    }

    [Theory]
    [InlineData(0.354f, 35)]
    [InlineData(0.3551f, 36)] // 0.355f itself is stored as 0.35499998
    [InlineData(0.3549f, 35)]
    [InlineData(-0.2f, 0)]
    [InlineData(1.7f, 100)]
    [InlineData(float.NaN, 0)]
    public void Scalars_round_to_whole_percents(float scalar, int expected) =>
        Assert.Equal(expected, VolumeMath.ToPercent(scalar));

    [Fact]
    public void Tiny_float_noise_does_not_change_the_percent()
    {
        var scalar = VolumeMath.ToScalar(37);
        Assert.Equal(37, VolumeMath.ToPercent(scalar + 0.0001f));
        Assert.Equal(37, VolumeMath.ToPercent(scalar - 0.0001f));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(101)]
    public void Out_of_range_levels_are_rejected(int level) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => VolumeMath.ToScalar(level));
}

public class RevertLogThrottleTests
{
    private readonly FakeTimeProvider _time = new();

    [Fact]
    public void First_revert_is_reported_and_bursts_are_summarised()
    {
        var throttle = new RevertLogThrottle(_time, TimeSpan.FromSeconds(10));

        Assert.Equal(1, throttle.Register("speakers"));
        for (var i = 0; i < 50; i++)
            Assert.Null(throttle.Register("speakers"));

        Assert.Empty(throttle.DrainExpired());
        _time.Advance(TimeSpan.FromSeconds(10));
        var drained = Assert.Single(throttle.DrainExpired());
        Assert.Equal(("speakers", 50), drained);
        Assert.Empty(throttle.DrainExpired());
    }

    [Fact]
    public void Keys_are_independent()
    {
        var throttle = new RevertLogThrottle(_time, TimeSpan.FromSeconds(10));
        Assert.Equal(1, throttle.Register("speakers"));
        Assert.Equal(1, throttle.Register("headphones"));
    }

    [Fact]
    public void A_revert_after_the_window_includes_suppressed_count()
    {
        var throttle = new RevertLogThrottle(_time, TimeSpan.FromSeconds(10));
        throttle.Register("speakers");
        throttle.Register("speakers");
        throttle.Register("speakers");
        _time.Advance(TimeSpan.FromSeconds(11));
        Assert.Equal(3, throttle.Register("speakers"));
    }
}
