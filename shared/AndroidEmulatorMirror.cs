// Copyright (c) 2026 DOTS
// Live Android emulator screen over the emulator's own gRPC service.

using System.Buffers.Binary;
using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace DotsHarnessCore;

/// <summary>A running emulator as announced in its discovery file (avd/running/pid_*.ini).</summary>
public sealed record AndroidEmulatorEndpoint(string Serial, string AvdName, int GrpcPort, string? Token, int ScreenWidth, int ScreenHeight)
{
    public static IReadOnlyList<AndroidEmulatorEndpoint> Running()
    {
        var result = new List<AndroidEmulatorEndpoint>();
        foreach (var directory in DiscoveryDirectories())
        {
            if (!Directory.Exists(directory)) continue;
            foreach (var file in Directory.EnumerateFiles(directory, "pid_*.ini"))
            {
                try
                {
                    var values = File.ReadAllLines(file)
                        .Select(line => line.Split('=', 2))
                        .Where(parts => parts.Length == 2)
                        .GroupBy(parts => parts[0].Trim())
                        .ToDictionary(group => group.Key, group => group.First()[1].Trim());
                    if (!values.TryGetValue("grpc.port", out var port) || !int.TryParse(port, out var grpcPort)) continue;
                    // The emulator leaves the file behind if it crashes; skip stale ones.
                    if (int.TryParse(Path.GetFileNameWithoutExtension(file)["pid_".Length..], out var pid) && !IsAlive(pid)) continue;
                    var (width, height) = ScreenSize(values.GetValueOrDefault("avd.dir"));
                    result.Add(new AndroidEmulatorEndpoint(
                        "emulator-" + values.GetValueOrDefault("port.serial", "5554"),
                        values.GetValueOrDefault("avd.name", "emulator"),
                        grpcPort,
                        values.GetValueOrDefault("grpc.token"),
                        width,
                        height));
                }
                catch (IOException) { }
            }
        }
        return result;
    }

    private static IEnumerable<string> DiscoveryDirectories()
    {
        if (OperatingSystem.IsWindows())
        {
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp", "avd", "running");
            yield return Path.Combine(Path.GetTempPath(), "avd", "running");
        }
        else if (OperatingSystem.IsMacOS())
        {
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Caches", "TemporaryItems", "avd", "running");
        }
        else
        {
            var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrWhiteSpace(runtime)) yield return Path.Combine(runtime, "avd", "running");
            yield return Path.Combine(Path.GetTempPath(), "android-" + Environment.UserName, "avd", "running");
        }
    }

    private static bool IsAlive(int pid)
    {
        try { using var process = System.Diagnostics.Process.GetProcessById(pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    /// <summary>Touch coordinates are in device pixels; the AVD's config.ini knows them.</summary>
    private static (int Width, int Height) ScreenSize(string? avdDirectory)
    {
        int width = 1080, height = 2400;
        if (avdDirectory is null) return (width, height);
        var config = Path.Combine(avdDirectory, "config.ini");
        if (!File.Exists(config)) return (width, height);
        foreach (var line in File.ReadLines(config))
        {
            var parts = line.Split('=', 2);
            if (parts.Length != 2) continue;
            if (parts[0].Trim() == "hw.lcd.width" && int.TryParse(parts[1].Trim(), out var w)) width = w;
            if (parts[0].Trim() == "hw.lcd.height" && int.TryParse(parts[1].Trim(), out var h)) height = h;
        }
        return (width, height);
    }
}

/// <summary>An AVD for the emulator panel's device menu; <see cref="Endpoint"/> is set while it runs.</summary>
public sealed record AndroidEmulatorTarget(string AvdName, AndroidEmulatorEndpoint? Endpoint)
{
    public bool IsRunning => Endpoint is not null;

    public override string ToString() => (IsRunning ? "● " : "▶ ") + AvdName;

    /// <summary>Running emulators first, then the AVDs that can be booted.</summary>
    public static async Task<IReadOnlyList<AndroidEmulatorTarget>> ListAsync(CancellationToken ct = default)
    {
        var running = AndroidEmulatorEndpoint.Running();
        IReadOnlyList<string> avds;
        try { avds = await AndroidEmulatorService.AvdsAsync(ct).ConfigureAwait(false); }
        catch (AndroidEmulatorException) { avds = []; }
        return running.Select(endpoint => new AndroidEmulatorTarget(endpoint.AvdName, endpoint))
            .Concat(avds.Where(avd => running.All(endpoint => endpoint.AvdName != avd)).Select(avd => new AndroidEmulatorTarget(avd, null)))
            .ToList();
    }

    /// <summary>Waits for a booting AVD to announce its gRPC endpoint.</summary>
    public static async Task<AndroidEmulatorEndpoint?> WaitForEndpointAsync(string avdName, TimeSpan timeout, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var endpoint = AndroidEmulatorEndpoint.Running().FirstOrDefault(candidate => candidate.AvdName == avdName);
            if (endpoint is not null) return endpoint;
            await Task.Delay(1000, ct).ConfigureAwait(false);
        }
        return null;
    }
}

/// <summary>
/// Streams the emulator screen through gRPC <c>streamScreenshot</c> and sends touch and key input back.
/// The emulator scales the frames itself and only sends one when the screen changes, so an idle screen
/// costs nothing. Only the newest frame is kept: a slow UI skips frames instead of falling behind.
/// </summary>
/// <remarks>
/// ponytail: plain HTTP/2 + a hand-rolled protobuf codec for the four messages used, instead of
/// Grpc.Net.Client, Google.Protobuf and codegen. Switch if more of the emulator API is needed.
/// </remarks>
public sealed class AndroidEmulatorMirror : IDisposable
{
    private const string Service = "/android.emulation.control.EmulatorController/";
    private readonly HttpClient _http;
    private readonly object _frameLock = new();
    private byte[] _frame = [];
    private int _frameWidth, _frameHeight, _frameLength;
    private bool _framePending;
    private CancellationTokenSource? _stream;

    public AndroidEmulatorMirror(AndroidEmulatorEndpoint endpoint)
    {
        Endpoint = endpoint;
        _http = new HttpClient(new SocketsHttpHandler { EnableMultipleHttp2Connections = false })
        {
            BaseAddress = new Uri($"http://127.0.0.1:{endpoint.GrpcPort}"),
            Timeout = Timeout.InfiniteTimeSpan,
        };
        if (!string.IsNullOrEmpty(endpoint.Token))
            _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", endpoint.Token);
    }

    public AndroidEmulatorEndpoint Endpoint { get; }

    /// <summary>Raised on a background thread when a new frame is waiting; at most once until it is taken.</summary>
    public event Action? FrameReady;

    /// <summary>Raised on a background thread when the stream ends with an error.</summary>
    public event Action<string>? Failed;

    public bool IsStreaming => _stream is not null;

    /// <summary>Starts streaming frames <paramref name="width"/> pixels wide; the emulator keeps the aspect ratio.</summary>
    public void Start(int width, bool rgba)
    {
        Stop();
        var cts = new CancellationTokenSource();
        _stream = cts;
        _ = Task.Run(async () =>
        {
            try { await StreamAsync(width, rgba, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (cts.IsCancellationRequested) { }
            catch (Exception error) { Failed?.Invoke(error.Message); }
        });
    }

    public void Stop()
    {
        _stream?.Cancel();
        _stream?.Dispose();
        _stream = null;
    }

    /// <summary>Hands the newest frame to <paramref name="copy"/>, which must copy it before returning.</summary>
    public bool TryTakeFrame(FrameCopy copy)
    {
        lock (_frameLock)
        {
            _framePending = false;
            if (_frameLength == 0) return false;
            copy(_frame, _frameLength, _frameWidth, _frameHeight);
            return true;
        }
    }

    public delegate void FrameCopy(byte[] pixels, int length, int width, int height);

    /// <summary>One finger at device pixel (x, y); <paramref name="down"/> false lifts it.</summary>
    public Task TouchAsync(int x, int y, bool down, CancellationToken ct = default)
    {
        var touch = new List<byte>();
        Varint(touch, 1, (ulong)Math.Max(0, x));
        Varint(touch, 2, (ulong)Math.Max(0, y));
        Varint(touch, 4, down ? 1UL : 0UL);
        var message = new List<byte>();
        Bytes(message, 1, touch.ToArray());
        return UnaryAsync("sendTouch", message.ToArray(), ct);
    }

    /// <summary>A W3C key name such as GoHome, GoBack, AppSwitch or Power.</summary>
    public Task KeyAsync(string key, CancellationToken ct = default)
    {
        var message = new List<byte>();
        Varint(message, 2, 2); // keypress
        Bytes(message, 4, Encoding.UTF8.GetBytes(key));
        return UnaryAsync("sendKey", message.ToArray(), ct);
    }

    public void Dispose()
    {
        Stop();
        _http.Dispose();
    }

    private async Task StreamAsync(int width, bool rgba, CancellationToken ct)
    {
        var format = new List<byte>();
        Varint(format, 1, rgba ? 1UL : 2UL); // RGBA8888 or RGB888
        Varint(format, 3, (ulong)width);
        using var request = Request("streamScreenshot", format.ToArray());
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        ThrowIfFailed(response);
        await using var body = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        var header = new byte[5];
        var message = Array.Empty<byte>();
        while (true)
        {
            if (!await ReadExactlyAsync(body, header, header.Length, ct).ConfigureAwait(false)) break;
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
            if (message.Length < length) message = new byte[length];
            if (!await ReadExactlyAsync(body, message, length, ct).ConfigureAwait(false)) break;
            Publish(message.AsSpan(0, length));
        }
        ThrowIfFailed(response);
    }

    /// <summary>Decodes an Image message and keeps its pixels as the newest frame.</summary>
    private void Publish(ReadOnlySpan<byte> image)
    {
        int width = 0, height = 0;
        ReadOnlySpan<byte> pixels = default;
        var position = 0;
        while (position < image.Length)
        {
            var (field, wire) = Tag(image, ref position);
            if (field == 1 && wire == 2)
            {
                var format = LengthDelimited(image, ref position);
                var inner = 0;
                while (inner < format.Length)
                {
                    var (formatField, formatWire) = Tag(format, ref inner);
                    if (formatField == 3 && formatWire == 0) width = (int)ReadVarint(format, ref inner);
                    else if (formatField == 4 && formatWire == 0) height = (int)ReadVarint(format, ref inner);
                    else Skip(format, ref inner, formatWire);
                }
            }
            else if (field == 4 && wire == 2) pixels = LengthDelimited(image, ref position);
            else Skip(image, ref position, wire);
        }
        // An inactive display streams empty images.
        if (width <= 0 || height <= 0 || pixels.IsEmpty) return;

        bool notify;
        lock (_frameLock)
        {
            if (_frame.Length < pixels.Length) _frame = new byte[pixels.Length];
            pixels.CopyTo(_frame);
            _frameLength = pixels.Length;
            _frameWidth = width;
            _frameHeight = height;
            notify = !_framePending;
            _framePending = true;
        }
        if (notify) FrameReady?.Invoke();
    }

    private async Task UnaryAsync(string method, byte[] message, CancellationToken ct)
    {
        using var request = Request(method, message);
        using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
        ThrowIfFailed(response);
    }

    private static HttpRequestMessage Request(string method, byte[] message)
    {
        var framed = new byte[message.Length + 5];
        BinaryPrimitives.WriteUInt32BigEndian(framed.AsSpan(1), (uint)message.Length);
        message.CopyTo(framed, 5);
        var content = new ByteArrayContent(framed);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/grpc");
        // h2c with prior knowledge; HttpClient's default version does not apply to hand-built requests.
        var request = new HttpRequestMessage(HttpMethod.Post, Service + method)
        {
            Content = content,
            Version = HttpVersion.Version20,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
        };
        request.Headers.TryAddWithoutValidation("te", "trailers");
        return request;
    }

    /// <summary>gRPC reports errors in headers (trailers-only) or trailers, with HTTP 200.</summary>
    private static void ThrowIfFailed(HttpResponseMessage response)
    {
        if (response.StatusCode != HttpStatusCode.OK)
            throw new AndroidEmulatorException($"Emulator gRPC returned HTTP {(int)response.StatusCode}.");
        foreach (var headers in new HttpHeaders[] { response.Headers, response.TrailingHeaders })
        {
            if (!headers.TryGetValues("grpc-status", out var status)) continue;
            var code = status.FirstOrDefault();
            if (code is null or "0") continue;
            var detail = headers.TryGetValues("grpc-message", out var messages) ? Uri.UnescapeDataString(messages.First()) : "";
            throw new AndroidEmulatorException($"Emulator gRPC error {code}: {detail}".TrimEnd(' ', ':'));
        }
    }

    private static async Task<bool> ReadExactlyAsync(Stream stream, byte[] buffer, int count, CancellationToken ct)
    {
        var read = 0;
        while (read < count)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(read, count - read), ct).ConfigureAwait(false);
            if (n == 0) return false;
            read += n;
        }
        return true;
    }

    // Protobuf wire format: just enough for ImageFormat, Image, TouchEvent and KeyboardEvent.

    private static void Varint(List<byte> output, int field, ulong value)
    {
        if (value == 0) return; // proto3 default
        WriteVarint(output, (ulong)(field << 3));
        WriteVarint(output, value);
    }

    private static void Bytes(List<byte> output, int field, byte[] value)
    {
        WriteVarint(output, (ulong)(field << 3 | 2));
        WriteVarint(output, (ulong)value.Length);
        output.AddRange(value);
    }

    private static void WriteVarint(List<byte> output, ulong value)
    {
        while (value >= 0x80)
        {
            output.Add((byte)(value | 0x80));
            value >>= 7;
        }
        output.Add((byte)value);
    }

    private static ulong ReadVarint(ReadOnlySpan<byte> data, ref int position)
    {
        ulong value = 0;
        for (var shift = 0; shift < 64 && position < data.Length; shift += 7)
        {
            var b = data[position++];
            value |= (ulong)(b & 0x7F) << shift;
            if (b < 0x80) return value;
        }
        throw new AndroidEmulatorException("Malformed emulator frame.");
    }

    private static (int Field, int Wire) Tag(ReadOnlySpan<byte> data, ref int position)
    {
        var tag = ReadVarint(data, ref position);
        return ((int)(tag >> 3), (int)(tag & 7));
    }

    private static ReadOnlySpan<byte> LengthDelimited(ReadOnlySpan<byte> data, scoped ref int position)
    {
        var length = (int)ReadVarint(data, ref position);
        if (length < 0 || position + length > data.Length) throw new AndroidEmulatorException("Malformed emulator frame.");
        var slice = data.Slice(position, length);
        position += length;
        return slice;
    }

    private static void Skip(ReadOnlySpan<byte> data, ref int position, int wire)
    {
        switch (wire)
        {
            case 0: ReadVarint(data, ref position); break;
            case 1: position += 8; break;
            case 2: LengthDelimited(data, ref position); break;
            case 5: position += 4; break;
            default: throw new AndroidEmulatorException("Malformed emulator frame.");
        }
    }
}
