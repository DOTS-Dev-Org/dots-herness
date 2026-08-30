using NAudio.Wave;

namespace DotsHarness.Views;

/// <summary>Small 16 kHz mono PCM16 capture adapter. It never runs inference.</summary>
public sealed class WindowsMicrophoneCapture : IDisposable
{
    private WaveInEvent? _capture;

    public event Action<ReadOnlyMemory<byte>>? DataAvailable;
    public bool IsRunning => _capture is not null;

    public void Start()
    {
        Stop();
        var capture = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16_000, 16, 1),
            BufferMilliseconds = 100,
            NumberOfBuffers = 3,
        };
        capture.DataAvailable += OnDataAvailable;
        _capture = capture;
        capture.StartRecording();
    }

    public void Stop()
    {
        if (_capture is not { } capture) return;
        _capture = null;
        capture.DataAvailable -= OnDataAvailable;
        try { capture.StopRecording(); } catch { }
        capture.Dispose();
    }

    public void Dispose() => Stop();

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded <= 0) return;
        var copy = new byte[e.BytesRecorded];
        Buffer.BlockCopy(e.Buffer, 0, copy, 0, e.BytesRecorded);
        DataAvailable?.Invoke(copy.AsMemory());
    }
}
