using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SteadyVolume.Core.Ipc;

public sealed class IpcProtocolException : Exception
{
    public IpcProtocolException(string message) : base(message) { }
    public IpcProtocolException(string message, Exception inner) : base(message, inner) { }
}

/// <summary>Length-prefixed JSON messages over any stream (named pipe or Unix socket).</summary>
public static class IpcFraming
{
    public const int MaxMessageBytes = 64 * 1024;

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };

    public static async Task WriteAsync<T>(Stream stream, T message, CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        if (payload.Length > MaxMessageBytes)
            throw new IpcProtocolException("Message too large.");

        var header = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task<T> ReadAsync<T>(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[4];
        await ReadExactlyOrThrowAsync(stream, header, cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length <= 0 || length > MaxMessageBytes)
            throw new IpcProtocolException($"Invalid message length {length}.");

        var payload = new byte[length];
        await ReadExactlyOrThrowAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        try
        {
            return JsonSerializer.Deserialize<T>(payload, JsonOptions)
                   ?? throw new IpcProtocolException("Empty message.");
        }
        catch (JsonException ex)
        {
            throw new IpcProtocolException("Malformed message.", ex);
        }
    }

    private static async Task ReadExactlyOrThrowAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        try
        {
            await stream.ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
        }
        catch (EndOfStreamException ex)
        {
            throw new IpcProtocolException("Connection closed before the message was complete.", ex);
        }
    }
}
