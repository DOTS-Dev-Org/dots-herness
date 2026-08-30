// Copyright (c) 2026 DOTS
// Small cross-platform realtime voice pipeline for the Windows and Linux shells.

using System.Diagnostics;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using HarnessPluginKit;
using PluginRuntime;
using Whisper.net;

namespace DotsHarnessCore;

public enum VoiceInputProvider
{
    WhisperTinyQ5,
    WhisperLargeV3Turbo,
    Nemotron,
    CustomLocal,
    Api,
}

public readonly record struct VoiceModelSpec(
    VoiceInputProvider Provider,
    string Id,
    string Name,
    string FileName,
    Uri? Url,
    long Bytes,
    string? Sha256);

public static class VoiceModelCatalog
{
    public static readonly VoiceModelSpec WhisperTinyQ5 = new(
        VoiceInputProvider.WhisperTinyQ5,
        "whisper-tiny-q5",
        "Whisper Tiny Q5 (fast)",
        "ggml-tiny-q5_1.bin",
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin?download=true"),
        32_152_673,
        "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7");

    public static readonly VoiceModelSpec WhisperLargeV3Turbo = new(
        VoiceInputProvider.WhisperLargeV3Turbo,
        "whisper-large-v3-turbo",
        "Whisper Large-v3-Turbo",
        "ggml-large-v3-turbo-q5_0.bin",
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true"),
        574_041_195,
        null);

    public static readonly VoiceModelSpec Nemotron = new(
        VoiceInputProvider.Nemotron,
        "nemotron-3.5-asr",
        "Nemotron 3.5 ASR Streaming 0.6B",
        "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf",
        new Uri("https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf?download=true"),
        741_548_352,
        "a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae");

    public static VoiceModelSpec For(VoiceInputProvider provider) => provider switch
    {
        VoiceInputProvider.WhisperTinyQ5 => WhisperTinyQ5,
        VoiceInputProvider.WhisperLargeV3Turbo => WhisperLargeV3Turbo,
        VoiceInputProvider.Nemotron => Nemotron,
        _ => default,
    };
}

public readonly record struct VoiceAPIConfiguration(
    string Endpoint,
    string ApiKey,
    string Model,
    string RealtimeEndpoint = "")
{
    public bool IsConfigured => !string.IsNullOrWhiteSpace(Endpoint) && !string.IsNullOrWhiteSpace(Model);
}

public readonly record struct VoiceTranscriptUpdate(string Text, bool IsFinal, Guid SessionId = default);

public enum VoiceActivityKind
{
    SpeechStarted,
    Audio,
    UtteranceEnded,
}

public readonly record struct VoiceActivityEvent(VoiceActivityKind Kind, float[] Samples)
{
    public static VoiceActivityEvent Ended => new(VoiceActivityKind.UtteranceEnded, Array.Empty<float>());
}

/// <summary>
/// 20 ms energy VAD with hysteresis, onset confirmation, pre-roll and hangover.
/// </summary>
public sealed class VoiceActivityDetector
{
    public const int SampleRate = 16_000;
    public const int FrameSamples = 320;
    public const int PreRollSamples = 3_200;
    public const int OnsetFrames = 10;
    public const int MinimumSpeechFrames = 12;
    public const int EndpointSilenceFrames = 40;

    private readonly List<float> _pending = new();
    private readonly List<float> _preRoll = new();
    private readonly List<float> _candidate = new();
    private bool _speaking;
    private int _aboveOnset;
    private int _silent;
    private float _noiseFloor = 0.008f;

    public IReadOnlyList<VoiceActivityEvent> Consume(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return Array.Empty<VoiceActivityEvent>();
        _pending.AddRange(samples.ToArray());
        var events = new List<VoiceActivityEvent>();
        while (_pending.Count >= FrameSamples)
        {
            var frame = _pending.Take(FrameSamples).ToArray();
            // ponytail: 20 ms frames keep this O(n) copy bounded; replace with a cursor only if profiling finds it hot.
            _pending.RemoveRange(0, FrameSamples);
            Process(frame, events);
        }
        return events;
    }

    public IReadOnlyList<VoiceActivityEvent> Flush()
    {
        var events = new List<VoiceActivityEvent>();
        if (_pending.Count > 0)
        {
            var frame = _pending.ToArray();
            _pending.Clear();
            Process(frame, events);
        }
        if (_speaking) events.Add(VoiceActivityEvent.Ended);
        Reset();
        return events;
    }

    public void Reset()
    {
        _pending.Clear();
        _preRoll.Clear();
        _candidate.Clear();
        _speaking = false;
        _aboveOnset = 0;
        _silent = 0;
    }

    private void Process(float[] frame, List<VoiceActivityEvent> events)
    {
        var level = Rms(frame);
        var startThreshold = Math.Max(0.018f, _noiseFloor * 3f);
        var stopThreshold = Math.Max(0.012f, _noiseFloor * 1.8f);

        if (_speaking)
        {
            events.Add(new VoiceActivityEvent(VoiceActivityKind.Audio, frame));
            if (level < stopThreshold)
            {
                _silent++;
                if (_silent >= EndpointSilenceFrames)
                {
                    events.Add(VoiceActivityEvent.Ended);
                    Reset();
                }
            }
            else
            {
                _silent = 0;
            }
            return;
        }

        if (level >= startThreshold)
        {
            _candidate.AddRange(frame);
            _aboveOnset++;
            if (_aboveOnset >= OnsetFrames && _candidate.Count >= MinimumSpeechFrames * FrameSamples)
            {
                _speaking = true;
                _silent = 0;
                var started = new float[_preRoll.Count + _candidate.Count];
                _preRoll.CopyTo(started, 0);
                _candidate.CopyTo(started, _preRoll.Count);
                _preRoll.Clear();
                _candidate.Clear();
                events.Add(new VoiceActivityEvent(VoiceActivityKind.SpeechStarted, started));
            }
            return;
        }

        _noiseFloor = Math.Min(0.2f, _noiseFloor * 0.95f + level * 0.05f);
        if (_candidate.Count > 0)
        {
            _preRoll.AddRange(_candidate);
            _candidate.Clear();
        }
        _preRoll.AddRange(frame);
        if (_preRoll.Count > PreRollSamples)
        {
            _preRoll.RemoveRange(0, _preRoll.Count - PreRollSamples);
        }
        _aboveOnset = 0;
    }

    private static float Rms(IReadOnlyList<float> frame)
    {
        if (frame.Count == 0) return 0;
        double sum = 0;
        foreach (var sample in frame) sum += sample * sample;
        return (float)Math.Sqrt(sum / frame.Count);
    }
}

public enum VoiceStreamingMode
{
    RollingWhisper,
    UtteranceHttp,
    Realtime,
}

/// <summary>
/// Owns the bounded audio queue and VAD. The capture callback only copies bytes
/// into this queue; inference, HTTP and WebSocket work run on the worker.
/// </summary>
public sealed class VoiceInputSession : IAsyncDisposable
{
    public delegate Task<string> BatchTranscriber(float[] samples, bool isFinal, CancellationToken ct);
    public delegate Task RealtimePusher(byte[] pcm16, CancellationToken ct);

    private readonly VoiceStreamingMode _mode;
    private readonly BatchTranscriber? _batch;
    private readonly RealtimePusher? _realtimePush;
    private readonly Func<CancellationToken, Task>? _realtimeCommit;
    private readonly Func<Task>? _realtimeCancel;
    private readonly Action<VoiceTranscriptUpdate> _onUpdate;
    private readonly Action<Exception> _onError;
    private readonly Guid _sessionId;
    private readonly Channel<byte[]> _audio = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(64)
    {
        SingleReader = true,
        FullMode = BoundedChannelFullMode.Wait,
    });
    private readonly CancellationTokenSource _cancel = new();
    private readonly VoiceActivityDetector _detector = new();
    private readonly Task _worker;
    private readonly object _stateLock = new();
    private readonly object _inferenceLock = new();
    private readonly List<float> _utterance = new();
    private readonly List<float> _rolling = new();
    private readonly List<float> _realtimePending = new();
    private bool _stopping;
    private bool _queueFullReported;
    private Task? _stopTask;
    private bool _inferenceRunning;
    private BatchRequest? _pendingInference;
    private TaskCompletionSource<bool> _inferenceDone = CompletedSource();
    private int _samplesSinceInference;

    private readonly record struct BatchRequest(float[] Samples, bool IsFinal);

    public VoiceInputSession(
        VoiceStreamingMode mode,
        BatchTranscriber? batch = null,
        RealtimePusher? realtimePush = null,
        Func<CancellationToken, Task>? realtimeCommit = null,
        Func<Task>? realtimeCancel = null,
        Action<VoiceTranscriptUpdate>? onUpdate = null,
        Action<Exception>? onError = null,
        Guid? sessionId = null)
    {
        _mode = mode;
        _batch = batch;
        _realtimePush = realtimePush;
        _realtimeCommit = realtimeCommit;
        _realtimeCancel = realtimeCancel;
        _onUpdate = onUpdate ?? (_ => { });
        _onError = onError ?? (_ => { });
        _sessionId = sessionId ?? Guid.NewGuid();
        _worker = Task.Run(WorkerLoopAsync);
    }

    public Guid SessionId => _sessionId;

    public void PushPcm16(ReadOnlySpan<byte> pcm16)
    {
        if (pcm16.Length < 2) return;
        var copy = pcm16[..(pcm16.Length - pcm16.Length % 2)].ToArray();
        lock (_stateLock)
        {
            if (_stopping || _cancel.IsCancellationRequested) return;
            if (_audio.Writer.TryWrite(copy)) return;
            if (_queueFullReported) return;
            _queueFullReported = true;
        }
        _onError(new InvalidOperationException("Voice audio queue is full."));
    }

    public Task StopAsync()
    {
        lock (_stateLock)
        {
            if (_stopTask is not null) return _stopTask;
            _stopping = true;
            _audio.Writer.TryComplete();
            _stopTask = StopCoreAsync();
            return _stopTask;
        }
    }

    public void Cancel()
    {
        lock (_stateLock)
        {
            if (_stopping && _cancel.IsCancellationRequested) return;
            _stopping = true;
            _audio.Writer.TryComplete();
            _cancel.Cancel();
        }
        _ = _realtimeCancel?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        Cancel();
        try { await _worker.ConfigureAwait(false); } catch { }
        _cancel.Dispose();
    }

    private async Task StopCoreAsync()
    {
        try
        {
            await _worker.ConfigureAwait(false);
            Task inference;
            lock (_inferenceLock) inference = _inferenceDone.Task;
            await inference.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_cancel.IsCancellationRequested) { }
    }

    private async Task WorkerLoopAsync()
    {
        try
        {
            await foreach (var pcm in _audio.Reader.ReadAllAsync(_cancel.Token).ConfigureAwait(false))
            {
                var samples = Pcm16ToFloat(pcm);
                foreach (var activity in _detector.Consume(samples))
                {
                    await ProcessActivityAsync(activity).ConfigureAwait(false);
                }
            }

            if (!_cancel.IsCancellationRequested)
            {
                foreach (var activity in _detector.Flush())
                {
                    await ProcessActivityAsync(activity).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (_cancel.IsCancellationRequested) { }
        catch (Exception error)
        {
            _onError(error);
        }
    }

    private async Task ProcessActivityAsync(VoiceActivityEvent activity)
    {
        switch (activity.Kind)
        {
            case VoiceActivityKind.SpeechStarted:
                Append(activity.Samples);
                if (_mode == VoiceStreamingMode.Realtime) await QueueRealtimeAsync(activity.Samples).ConfigureAwait(false);
                break;
            case VoiceActivityKind.Audio:
                Append(activity.Samples);
                if (_mode == VoiceStreamingMode.Realtime)
                {
                    await QueueRealtimeAsync(activity.Samples).ConfigureAwait(false);
                }
                else if (_mode == VoiceStreamingMode.RollingWhisper)
                {
                    _samplesSinceInference += activity.Samples.Length;
                    if (_samplesSinceInference >= 5_120 && _utterance.Count >= VoiceActivityDetector.SampleRate)
                    {
                        _samplesSinceInference = 0;
                        ScheduleBatch(_rolling.ToArray(), isFinal: false);
                    }
                }
                break;
            case VoiceActivityKind.UtteranceEnded:
                if (_mode == VoiceStreamingMode.Realtime)
                {
                    await CommitRealtimeAsync().ConfigureAwait(false);
                }
                else
                {
                    ScheduleBatch(_utterance.ToArray(), isFinal: true);
                }
                _utterance.Clear();
                _rolling.Clear();
                _realtimePending.Clear();
                _samplesSinceInference = 0;
                break;
        }
    }

    private void Append(float[] samples)
    {
        if (samples.Length == 0) return;
        _utterance.AddRange(samples);
        if (_utterance.Count > VoiceActivityDetector.SampleRate * 30)
        {
            // ponytail: cap one utterance at 30 s; split at the next endpoint instead of retaining an unbounded recording.
            _utterance.RemoveRange(0, _utterance.Count - VoiceActivityDetector.SampleRate * 30);
        }
        _rolling.AddRange(samples);
        if (_rolling.Count > 48_000) _rolling.RemoveRange(0, _rolling.Count - 48_000);
    }

    private async Task QueueRealtimeAsync(float[] samples)
    {
        if (_realtimePush is null || samples.Length == 0) return;
        _realtimePending.AddRange(samples);
        while (_realtimePending.Count >= 2_560)
        {
            var chunk = _realtimePending.Take(2_560).ToArray();
            _realtimePending.RemoveRange(0, 2_560);
            await _realtimePush(FloatToPcm16(chunk), _cancel.Token).ConfigureAwait(false);
        }
    }

    private async Task CommitRealtimeAsync()
    {
        if (_realtimePush is not null && _realtimePending.Count > 0)
        {
            var tail = _realtimePending.ToArray();
            _realtimePending.Clear();
            await _realtimePush(FloatToPcm16(tail), _cancel.Token).ConfigureAwait(false);
        }
        if (_realtimeCommit is not null) await _realtimeCommit(_cancel.Token).ConfigureAwait(false);
    }

    private void ScheduleBatch(float[] samples, bool isFinal)
    {
        if (_batch is null || samples.Length < 1_600) return;
        var request = new BatchRequest(samples, isFinal);
        var start = false;
        lock (_inferenceLock)
        {
            if (_inferenceRunning)
            {
                _pendingInference = request;
            }
            else
            {
                _inferenceRunning = true;
                _inferenceDone = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                start = true;
            }
        }
        if (start) _ = RunBatchAsync(request);
    }

    private async Task RunBatchAsync(BatchRequest request)
    {
        try
        {
            var text = (await _batch!(request.Samples, request.IsFinal, _cancel.Token).ConfigureAwait(false)).Trim();
            if (!string.IsNullOrWhiteSpace(text)) _onUpdate(new VoiceTranscriptUpdate(text, request.IsFinal, _sessionId));
        }
        catch (OperationCanceledException) when (_cancel.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (request.IsFinal) _onError(error);
        }

        BatchRequest? next;
        TaskCompletionSource<bool>? done = null;
        lock (_inferenceLock)
        {
            next = _pendingInference;
            _pendingInference = null;
            if (next is null)
            {
                _inferenceRunning = false;
                done = _inferenceDone;
            }
        }
        if (next is { } queued) _ = RunBatchAsync(queued);
        else done?.TrySetResult(true);
    }

    private static TaskCompletionSource<bool> CompletedSource()
    {
        var source = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        source.TrySetResult(true);
        return source;
    }

    private static float[] Pcm16ToFloat(byte[] pcm)
    {
        var result = new float[pcm.Length / 2];
        for (var i = 0; i < result.Length; i++)
        {
            var value = (short)(pcm[i * 2] | pcm[i * 2 + 1] << 8);
            result[i] = value / 32_768f;
        }
        return result;
    }

    private static byte[] FloatToPcm16(IReadOnlyList<float> samples)
    {
        var result = new byte[samples.Count * 2];
        for (var i = 0; i < samples.Count; i++)
        {
            var value = (short)(Math.Clamp(samples[i], -1f, 1f) * 32_767f);
            result[i * 2] = (byte)(value & 0xff);
            result[i * 2 + 1] = (byte)((value >> 8) & 0xff);
        }
        return result;
    }
}

public static class VoiceHttpTranscriber
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(120) };

    public static async Task<string> TranscribeAsync(
        float[] samples,
        VoiceAPIConfiguration configuration,
        CancellationToken ct = default)
    {
        if (!configuration.IsConfigured) throw new RouterException("Voice API endpoint and model are required.");
        using var content = new MultipartFormDataContent();
        content.Add(new StringContent(configuration.Model), "model");
        content.Add(new StringContent("json"), "response_format");
        var audio = new ByteArrayContent(MakeWav(samples));
        audio.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        content.Add(audio, "file", "recording.wav");
        using var request = new HttpRequestMessage(HttpMethod.Post, TranscriptionUri(configuration.Endpoint))
        {
            Content = content,
        };
        if (!string.IsNullOrWhiteSpace(configuration.ApiKey))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", configuration.ApiKey);
        }
        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new RouterException($"Voice API HTTP {(int)response.StatusCode}: {body[..Math.Min(body.Length, 220)]}");
        }
        using var document = JsonDocument.Parse(body);
        var text = document.RootElement.TryGetProperty("text", out var value) ? value.GetString() : null;
        if (string.IsNullOrWhiteSpace(text)) throw new RouterException("Voice API returned no transcript.");
        return text.Trim();
    }

    public static Uri TranscriptionUri(string raw)
    {
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var source) || string.IsNullOrEmpty(source.Host))
            throw new RouterException("Voice API address is invalid.");
        var path = source.AbsolutePath.TrimEnd('/');
        if (!path.EndsWith("/audio/transcriptions", StringComparison.OrdinalIgnoreCase))
        {
            if (path.Length == 0) path = "/v1";
            else if (!path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)) path += "/v1";
            path += "/audio/transcriptions";
        }
        return new UriBuilder(source) { Path = path }.Uri;
    }

    public static byte[] MakeWav(IReadOnlyList<float> samples, int sampleRate = VoiceActivityDetector.SampleRate)
    {
        var pcm = new byte[samples.Count * 2];
        for (var i = 0; i < samples.Count; i++)
        {
            var value = (short)(Math.Clamp(samples[i], -1f, 1f) * 32_767f);
            pcm[i * 2] = (byte)(value & 0xff);
            pcm[i * 2 + 1] = (byte)((value >> 8) & 0xff);
        }
        using var output = new MemoryStream(44 + pcm.Length);
        using var writer = new BinaryWriter(output, Encoding.UTF8, leaveOpen: true);
        writer.Write(Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + pcm.Length);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(sampleRate);
        writer.Write(sampleRate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data"));
        writer.Write(pcm.Length);
        writer.Write(pcm);
        return output.ToArray();
    }
}

public sealed class VoiceRealtimeClient : IAsyncDisposable
{
    private readonly Uri _endpoint;
    private readonly string _apiKey;
    private readonly Action<VoiceTranscriptUpdate> _onUpdate;
    private readonly Action<Exception> _onError;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly object _completionLock = new();
    private readonly CancellationTokenSource _cancel = new();
    private ClientWebSocket? _socket;
    private Task? _receiveTask;
    private string _partial = "";
    private TaskCompletionSource<bool> _completion = CompletedSource();

    public VoiceRealtimeClient(
        string endpoint,
        string apiKey,
        Action<VoiceTranscriptUpdate> onUpdate,
        Action<Exception> onError)
    {
        _endpoint = RealtimeUri(endpoint);
        _apiKey = apiKey;
        _onUpdate = onUpdate;
        _onError = onError;
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        var socket = new ClientWebSocket();
        if (!string.IsNullOrWhiteSpace(_apiKey)) socket.Options.SetRequestHeader("Authorization", $"Bearer {_apiKey}");
        await socket.ConnectAsync(_endpoint, ct).ConfigureAwait(false);
        _socket = socket;
        using var handshakeCancel = CancellationTokenSource.CreateLinkedTokenSource(ct);
        handshakeCancel.CancelAfter(TimeSpan.FromSeconds(3));
        var first = await ReceiveTextAsync(socket, handshakeCancel.Token).ConfigureAwait(false);
        if (!EventType(first).Equals("session.created", StringComparison.OrdinalIgnoreCase))
        {
            await DisposeSocketAsync().ConfigureAwait(false);
            throw new RouterException("Voice realtime endpoint is not a NeMo-compatible server.");
        }
        await SendJsonAsync(new
        {
            type = "session.update",
            session = new
            {
                sample_rate = VoiceActivityDetector.SampleRate,
                language = "auto",
                automatic_punctuation = true,
                endpointing_ms = 800,
            },
        }, ct).ConfigureAwait(false);
        _receiveTask = ReceiveLoopAsync(socket);
    }

    public Task SendPcm16Async(byte[] pcm16, CancellationToken ct = default) =>
        SendBinaryAsync(pcm16, ct);

    public async Task CommitAsync(CancellationToken ct = default)
    {
        lock (_completionLock)
        {
            _completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        await SendJsonAsync(new { type = "input_audio_buffer.commit" }, ct).ConfigureAwait(false);
    }

    public async Task WaitForCompletionAsync(TimeSpan timeout, CancellationToken ct = default)
    {
        Task completion;
        lock (_completionLock) completion = _completion.Task;
        var delay = Task.Delay(timeout, ct);
        await Task.WhenAny(completion, delay).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        _cancel.Cancel();
        try { if (_receiveTask is not null) await _receiveTask.ConfigureAwait(false); } catch { }
        await DisposeSocketAsync().ConfigureAwait(false);
        _sendLock.Dispose();
        _cancel.Dispose();
    }

    private async Task SendBinaryAsync(byte[] data, CancellationToken ct)
    {
        var socket = _socket ?? throw new InvalidOperationException("Voice realtime socket is not connected.");
        await _sendLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await socket.SendAsync(data.AsMemory(), WebSocketMessageType.Binary, endOfMessage: true, ct).ConfigureAwait(false);
        }
        finally { _sendLock.Release(); }
    }

    private async Task SendJsonAsync(object message, CancellationToken ct)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(message);
        var socket = _socket ?? throw new InvalidOperationException("Voice realtime socket is not connected.");
        await _sendLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await socket.SendAsync(bytes.AsMemory(), WebSocketMessageType.Text, endOfMessage: true, ct).ConfigureAwait(false);
        }
        finally { _sendLock.Release(); }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket socket)
    {
        try
        {
            while (!_cancel.IsCancellationRequested)
            {
                var json = await ReceiveTextAsync(socket, _cancel.Token).ConfigureAwait(false);
                Handle(json);
            }
        }
        catch (OperationCanceledException) when (_cancel.IsCancellationRequested) { }
        catch (WebSocketException) when (_cancel.IsCancellationRequested) { }
        catch (Exception error)
        {
            _onError(error);
        }
    }

    private void Handle(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var type = root.TryGetProperty("type", out var typeValue) ? typeValue.GetString() ?? "" : "";
        if (type.Equals("error", StringComparison.OrdinalIgnoreCase))
        {
            var message = root.TryGetProperty("error", out var error)
                && error.TryGetProperty("message", out var detail)
                ? detail.GetString() ?? "Voice realtime error."
                : "Voice realtime error.";
            _onError(new RouterException(message));
            return;
        }
        if (type.Contains("transcription.delta", StringComparison.OrdinalIgnoreCase))
        {
            var delta = root.TryGetProperty("delta", out var deltaValue) ? deltaValue.GetString() : null;
            delta ??= root.TryGetProperty("text", out var textValue) ? textValue.GetString() : null;
            if (string.IsNullOrEmpty(delta)) return;
            _partial += delta;
            _onUpdate(new VoiceTranscriptUpdate(_partial, false));
        }
        else if (type.Contains("transcription.completed", StringComparison.OrdinalIgnoreCase))
        {
            var text = root.TryGetProperty("text", out var textValue) ? textValue.GetString() : null;
            text ??= root.TryGetProperty("transcript", out var transcriptValue) ? transcriptValue.GetString() : null;
            text = string.IsNullOrWhiteSpace(text) ? _partial : text;
            _partial = "";
            if (!string.IsNullOrWhiteSpace(text)) _onUpdate(new VoiceTranscriptUpdate(text.Trim(), true));
            lock (_completionLock) _completion.TrySetResult(true);
        }
        else if (type.Contains("speech_stopped", StringComparison.OrdinalIgnoreCase)
                 || type.Contains("endpoint", StringComparison.OrdinalIgnoreCase))
        {
            // Local VAD owns commits; this event only unblocks stop/wait callers.
            lock (_completionLock) _completion.TrySetResult(true);
        }
    }

    private static async Task<string> ReceiveTextAsync(ClientWebSocket socket, CancellationToken ct)
    {
        using var output = new MemoryStream();
        var buffer = new byte[8_192];
        ValueWebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(buffer.AsMemory(), ct).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) throw new WebSocketException("Voice realtime socket closed.");
            output.Write(buffer, 0, result.Count);
        }
        while (!result.EndOfMessage);
        return Encoding.UTF8.GetString(output.ToArray());
    }

    private async Task DisposeSocketAsync()
    {
        if (_socket is not { } socket) return;
        _socket = null;
        try
        {
            if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "done", CancellationToken.None).ConfigureAwait(false);
        }
        catch { }
        socket.Dispose();
    }

    private static string EventType(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.TryGetProperty("type", out var value) ? value.GetString() ?? "" : "";
    }

    public static Uri RealtimeUri(string raw)
    {
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var source) || string.IsNullOrEmpty(source.Host))
            throw new RouterException("Voice realtime address is invalid.");
        var builder = new UriBuilder(source)
        {
            Scheme = source.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ? "wss" : "ws",
        };
        var path = builder.Path.TrimEnd('/');
        if (!path.EndsWith("/realtime", StringComparison.OrdinalIgnoreCase))
        {
            if (path.Length == 0) path = "/v1";
            else if (!path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)) path += "/v1";
            path += "/realtime";
        }
        builder.Path = path;
        return builder.Uri;
    }

    private static TaskCompletionSource<bool> CompletedSource()
    {
        var source = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        source.TrySetResult(true);
        return source;
    }
}

public sealed class NemotronVoiceRuntime : IDisposable
{
    public const int DefaultPort = 18_767;
    public SupportPaths Paths { get; }
    public int Port { get; }

    private Process? _process;
    private string RuntimeRoot => Path.Combine(Paths.Runtime, "nemo-speech");

    public NemotronVoiceRuntime(SupportPaths paths, int port = DefaultPort)
    {
        Paths = paths;
        Port = port;
        paths.Ensure();
    }

    public Uri ServerUrl => new($"http://127.0.0.1:{Port}/v1");
    public string ModelPath => Path.Combine(Paths.Models, VoiceModelCatalog.Nemotron.FileName);
    public string BinaryPath => FindBinary() ?? Path.Combine(RuntimeRoot, OperatingSystem.IsWindows() ? "nemo-speech.exe" : "nemo-speech");
    public bool IsModelInstalled => File.Exists(ModelPath) && new FileInfo(ModelPath).Length == VoiceModelCatalog.Nemotron.Bytes;
    public bool IsRuntimeInstalled => FindBinary() is not null;
    public bool IsReady => IsModelInstalled && IsRuntimeInstalled;

    public async Task EnsureAssetsAsync(Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default)
    {
        var asset = CurrentAsset();
        if (!IsRuntimeInstalled)
        {
            var archive = Path.Combine(Paths.Runtime, asset.FileName);
            await FileDownloader.DownloadAsync(asset.Url, archive, asset.Bytes, progress, ct, asset.Sha256);
            Unpack(archive);
        }
        if (!IsModelInstalled)
        {
            await FileDownloader.DownloadAsync(
                VoiceModelCatalog.Nemotron.Url!,
                ModelPath,
                VoiceModelCatalog.Nemotron.Bytes,
                progress,
                ct,
                VoiceModelCatalog.Nemotron.Sha256);
        }
    }

    public Uri Start()
    {
        if (_process is { HasExited: false }) return ServerUrl;
        Stop();
        if (!IsReady) throw new RouterException("Nemotron voice runtime and model are not ready.");
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = BinaryPath,
                WorkingDirectory = RuntimeRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = false,
                RedirectStandardError = false,
            },
        };
        process.StartInfo.ArgumentList.Add("serve");
        process.StartInfo.ArgumentList.Add("--asr-model");
        process.StartInfo.ArgumentList.Add(ModelPath);
        process.StartInfo.ArgumentList.Add("--device");
        process.StartInfo.ArgumentList.Add("cpu");
        process.StartInfo.ArgumentList.Add("--no-ui");
        process.StartInfo.ArgumentList.Add("--host");
        process.StartInfo.ArgumentList.Add("127.0.0.1");
        process.StartInfo.ArgumentList.Add("--port");
        process.StartInfo.ArgumentList.Add(Port.ToString());
        process.StartInfo.ArgumentList.Add("--endpointing");
        process.StartInfo.ArgumentList.Add("--stop-history-eou-ms");
        process.StartInfo.ArgumentList.Add("800");
        if (!process.Start()) throw new RouterException("Nemotron voice runtime could not start.");
        _process = process;
        return ServerUrl;
    }

    public async Task<bool> WaitUntilReadyAsync(int timeoutMs = 60_000, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (_process is { HasExited: true }) return false;
            if (await PingAsync(ct).ConfigureAwait(false)) return true;
            await Task.Delay(250, ct).ConfigureAwait(false);
        }
        return await PingAsync(ct).ConfigureAwait(false);
    }

    public async Task<bool> PingAsync(CancellationToken ct = default)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        foreach (var path in new[] { "/ready", "/v1/models" })
        {
            try
            {
                using var response = await http.GetAsync($"http://127.0.0.1:{Port}{path}", ct).ConfigureAwait(false);
                if ((int)response.StatusCode is >= 200 and < 500) return true;
            }
            catch { }
        }
        return false;
    }

    public void Stop()
    {
        try
        {
            if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true);
        }
        catch { }
        _process = null;
    }

    public void Dispose() => Stop();

    public static RuntimeAsset CurrentAsset()
    {
        var arm64 = RuntimeInformation.ProcessArchitecture == Architecture.Arm64;
        if (OperatingSystem.IsWindows())
        {
            if (arm64) throw new RouterException("Nemotron Windows runtime is currently available for x64 only.");
            return new RuntimeAsset(
                "nemo-speech-0.1.0-windows-x86_64-cpu.zip",
                new Uri("https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.1.0/nemo-speech-0.1.0-windows-x86_64-cpu.zip"),
                4_730_421,
                "5e4ea81046012edcd77fd8848de8eefb5a4ba38cc26f52eb544ab184695a75d6");
        }
        return arm64
            ? new RuntimeAsset(
                "nemo-speech-0.1.0-linux-aarch64-cpu.tar.gz",
                new Uri("https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.1.0/nemo-speech-0.1.0-linux-aarch64-cpu.tar.gz"),
                4_328_117,
                "0e4112255d566de7bdd142f239e984995c4447103ba8feb41f2bb5c559d561d3")
            : new RuntimeAsset(
                "nemo-speech-0.1.0-linux-x86_64-cpu.tar.gz",
                new Uri("https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.1.0/nemo-speech-0.1.0-linux-x86_64-cpu.tar.gz"),
                4_583_913,
                "0f74131d631ad2c694cf0ec53490866bb6461147959589a69fb6fc231944065b");
    }

    public readonly record struct RuntimeAsset(string FileName, Uri Url, long Bytes, string Sha256);

    private void Unpack(string archive)
    {
        var staging = Path.Combine(Paths.Runtime, $"nemo-speech-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        try
        {
            if (OperatingSystem.IsWindows())
            {
                System.IO.Compression.ZipFile.ExtractToDirectory(archive, staging, overwriteFiles: true);
            }
            else
            {
                using var extractor = Process.Start(new ProcessStartInfo
                {
                    FileName = "tar",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    ArgumentList = { "-xzf", archive, "-C", staging },
                }) ?? throw new RouterException("tar could not start for the Nemotron runtime.");
                extractor.WaitForExit();
                if (extractor.ExitCode != 0) throw new RouterException("Nemotron runtime archive could not be unpacked.");
            }
            var binary = FindBinary(staging) ?? throw new RouterException("Nemotron runtime binary is missing.");
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(binary, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            if (Directory.Exists(RuntimeRoot)) Directory.Delete(RuntimeRoot, recursive: true);
            Directory.Move(staging, RuntimeRoot);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    private string? FindBinary(string? root = null)
    {
        root ??= RuntimeRoot;
        if (!Directory.Exists(root)) return null;
        var names = OperatingSystem.IsWindows() ? new[] { "nemo-speech.exe", "nemo-speech" } : new[] { "nemo-speech" };
        return Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .FirstOrDefault(path => names.Contains(Path.GetFileName(path), StringComparer.OrdinalIgnoreCase));
    }
}

public sealed class VoiceInputController : ObservableObject, IDisposable
{
    private readonly SupportPaths _paths;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private readonly SemaphoreSlim _whisperLock = new(1, 1);
    private readonly NemotronVoiceRuntime _nemotron;
    private WhisperFactory? _whisperFactory;
    private WhisperProcessor? _whisperProcessor;
    private VoiceInputSession? _session;
    private VoiceRealtimeClient? _realtime;
    private VoiceInputProvider _provider = VoiceInputProvider.WhisperTinyQ5;
    private VoiceAPIConfiguration _api;
    private string _customModelPath = "";
    private Guid _sessionId;

    public event EventHandler<VoiceTranscriptUpdate>? TranscriptUpdated;
    public event EventHandler<Exception>? Error;

    public VoiceInputProvider Provider { get => _provider; private set => SetProperty(ref _provider, value); }
    public string ApiEndpoint { get => _api.Endpoint; private set { if (_api.Endpoint != value) { _api = _api with { Endpoint = value }; OnPropertyChanged(); OnPropertyChanged(nameof(IsReady)); } } }
    public string ApiKey { get => _api.ApiKey; private set { if (_api.ApiKey != value) { _api = _api with { ApiKey = value }; OnPropertyChanged(); } } }
    public string ApiModel { get => _api.Model; private set { if (_api.Model != value) { _api = _api with { Model = value }; OnPropertyChanged(); OnPropertyChanged(nameof(IsReady)); } } }
    public string RealtimeEndpoint { get => _api.RealtimeEndpoint; private set { if (_api.RealtimeEndpoint != value) { _api = _api with { RealtimeEndpoint = value }; OnPropertyChanged(); } } }
    public string CustomModelPath { get => _customModelPath; private set => SetProperty(ref _customModelPath, value); }
    public bool IsRunning => _session is not null;
    public Guid SessionId => _sessionId;

    public bool IsReady => Provider switch
    {
        VoiceInputProvider.Api => _api.IsConfigured,
        VoiceInputProvider.Nemotron => _nemotron.IsReady,
        VoiceInputProvider.CustomLocal => File.Exists(CustomModelPath) && new FileInfo(CustomModelPath).Length > 0,
        _ => LocalModelReady(VoiceModelCatalog.For(Provider)),
    };

    public VoiceInputController(SupportPaths paths)
    {
        _paths = paths;
        _nemotron = new NemotronVoiceRuntime(paths);
    }

    public void Configure(
        VoiceInputProvider provider,
        string endpoint,
        string apiKey,
        string model,
        string realtimeEndpoint,
        string customModelPath = "")
    {
        Cancel();
        _whisperProcessor?.Dispose();
        _whisperFactory?.Dispose();
        _whisperProcessor = null;
        _whisperFactory = null;
        Provider = provider;
        _api = new VoiceAPIConfiguration(endpoint, apiKey, model, realtimeEndpoint);
        CustomModelPath = customModelPath;
        OnPropertyChanged(nameof(ApiEndpoint));
        OnPropertyChanged(nameof(ApiKey));
        OnPropertyChanged(nameof(ApiModel));
        OnPropertyChanged(nameof(RealtimeEndpoint));
        OnPropertyChanged(nameof(IsReady));
    }

    public async Task EnsureAssetsAsync(Action<FileDownloader.Progress>? progress = null, CancellationToken ct = default)
    {
        switch (Provider)
        {
            case VoiceInputProvider.Nemotron:
                await _nemotron.EnsureAssetsAsync(progress, ct).ConfigureAwait(false);
                break;
            case VoiceInputProvider.WhisperTinyQ5:
            case VoiceInputProvider.WhisperLargeV3Turbo:
                var model = VoiceModelCatalog.For(Provider);
                await FileDownloader.DownloadAsync(
                    model.Url!,
                    Path.Combine(_paths.Models, model.FileName),
                    model.Bytes,
                    progress,
                    ct,
                    model.Sha256).ConfigureAwait(false);
                break;
            default:
                break;
        }
        OnPropertyChanged(nameof(IsReady));
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        await _lifecycle.WaitAsync(ct).ConfigureAwait(false);
        VoiceRealtimeClient? realtime = null;
        try
        {
            if (_session is not null) return;
            var sessionId = Guid.NewGuid();
            VoiceStreamingMode mode;
            VoiceInputSession.BatchTranscriber? batch = null;

            switch (Provider)
            {
                case VoiceInputProvider.Api:
                    if (!_api.IsConfigured) throw new RouterException("Voice API endpoint and model are required.");
                    if (!string.IsNullOrWhiteSpace(_api.RealtimeEndpoint))
                    {
                        try
                        {
                            realtime = new VoiceRealtimeClient(
                                _api.RealtimeEndpoint,
                                _api.ApiKey,
                                update => TranscriptUpdated?.Invoke(this, update with { SessionId = sessionId }),
                                error => Error?.Invoke(this, error));
                            await realtime.StartAsync(ct).ConfigureAwait(false);
                        }
                        catch (OperationCanceledException) when (ct.IsCancellationRequested)
                        {
                            throw;
                        }
                        catch
                        {
                            await realtime.DisposeAsync().ConfigureAwait(false);
                            realtime = null;
                        }
                    }
                    if (realtime is not null)
                    {
                        mode = VoiceStreamingMode.Realtime;
                    }
                    else
                    {
                        mode = VoiceStreamingMode.UtteranceHttp;
                        batch = (samples, _, token) => VoiceHttpTranscriber.TranscribeAsync(samples, _api, token);
                    }
                    break;
                case VoiceInputProvider.Nemotron:
                    if (!_nemotron.IsReady) throw new RouterException("Nemotron voice runtime and model are not ready.");
                    _nemotron.Start();
                    if (!await _nemotron.WaitUntilReadyAsync(ct: ct).ConfigureAwait(false))
                        throw new RouterException("Nemotron voice runtime did not become ready.");
                    realtime = new VoiceRealtimeClient(
                        _nemotron.ServerUrl.ToString(),
                        "",
                        update => TranscriptUpdated?.Invoke(this, update with { SessionId = sessionId }),
                        error => Error?.Invoke(this, error));
                    await realtime.StartAsync(ct).ConfigureAwait(false);
                    mode = VoiceStreamingMode.Realtime;
                    break;
                case VoiceInputProvider.WhisperTinyQ5:
                case VoiceInputProvider.WhisperLargeV3Turbo:
                case VoiceInputProvider.CustomLocal:
                    if (!IsReady) throw new RouterException("The selected local voice model is not ready.");
                    mode = VoiceStreamingMode.RollingWhisper;
                    batch = (samples, _, token) => TranscribeLocalAsync(samples, token);
                    break;
                default:
                    throw new RouterException("Voice provider is not configured.");
            }

            var activeRealtime = realtime;
            var candidate = new VoiceInputSession(
                mode,
                batch,
                activeRealtime is null ? null : activeRealtime.SendPcm16Async,
                activeRealtime is null ? null : activeRealtime.CommitAsync,
                activeRealtime is null ? null : () => activeRealtime.DisposeAsync().AsTask(),
                update => TranscriptUpdated?.Invoke(this, update),
                error => Error?.Invoke(this, error),
                sessionId);
            _realtime = realtime;
            _session = candidate;
            _sessionId = sessionId;
            OnPropertyChanged(nameof(IsRunning));
        }
        catch
        {
            if (realtime is not null) await realtime.DisposeAsync().ConfigureAwait(false);
            _nemotron.Stop();
            throw;
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public void PushPcm16(ReadOnlySpan<byte> pcm16) => _session?.PushPcm16(pcm16);

    public async Task StopAsync(CancellationToken ct = default)
    {
        await _lifecycle.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var session = _session;
            if (session is null) return;
            await session.StopAsync().ConfigureAwait(false);
            if (_realtime is not null) await _realtime.WaitForCompletionAsync(TimeSpan.FromMilliseconds(900), ct).ConfigureAwait(false);
            await session.DisposeAsync().ConfigureAwait(false);
            _session = null;
            _realtime = null;
            _nemotron.Stop();
            OnPropertyChanged(nameof(IsRunning));
        }
        finally { _lifecycle.Release(); }
    }

    public void Cancel()
    {
        _session?.Cancel();
        _session = null;
        _realtime = null;
        _nemotron.Stop();
        OnPropertyChanged(nameof(IsRunning));
    }

    public void Dispose()
    {
        Cancel();
        _whisperProcessor?.Dispose();
        _whisperFactory?.Dispose();
        _lifecycle.Dispose();
        _whisperLock.Dispose();
        _nemotron.Dispose();
    }

    private async Task<string> TranscribeLocalAsync(float[] samples, CancellationToken ct)
    {
        await _whisperLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var path = Provider == VoiceInputProvider.CustomLocal
                ? CustomModelPath
                : Path.Combine(_paths.Models, VoiceModelCatalog.For(Provider).FileName);
            _whisperFactory ??= WhisperFactory.FromPath(path);
            _whisperProcessor ??= _whisperFactory.CreateBuilder()
                .WithLanguage("auto")
                .WithNoContext()
                .WithSingleSegment()
                .WithThreads(Math.Max(1, Environment.ProcessorCount - 1))
                .Build();
            var text = new StringBuilder();
            await foreach (var segment in _whisperProcessor.ProcessAsync(samples.AsMemory()).WithCancellation(ct).ConfigureAwait(false))
            {
                text.Append(segment.Text);
            }
            return text.ToString();
        }
        finally { _whisperLock.Release(); }
    }

    private bool LocalModelReady(VoiceModelSpec model)
    {
        if (model.Bytes <= 0) return false;
        var path = Path.Combine(_paths.Models, model.FileName);
        return File.Exists(path) && new FileInfo(path).Length == model.Bytes;
    }
}
