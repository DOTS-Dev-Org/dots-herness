// Copyright (c) 2026 DOTS
// Local desktop video trimming shared by Windows and Linux.

using System.Diagnostics;
using System.Globalization;

namespace DotsHarnessCore;

public static class MediaVideoTools
{
    /// <summary>Frame-accurate local MP4 export. Requires a discoverable FFmpeg executable.</summary>
    public static async Task TrimMp4Async(string input, string output, double startSeconds, double endSeconds,
        IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(input)) throw new FileNotFoundException(LocalizationService.Current.Get("studio.video.sourceMissing"), input);
        if (!double.IsFinite(startSeconds) || !double.IsFinite(endSeconds) || startSeconds < 0 || endSeconds <= startSeconds)
            throw new ArgumentOutOfRangeException(nameof(endSeconds), "The Out point must be after the In point.");
        var ffmpeg = FindFfmpeg() ?? throw new FileNotFoundException(LocalizationService.Current.Get("studio.video.ffmpegMissing"));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
        var duration = endSeconds - startSeconds;
        var start = startSeconds.ToString("0.######", CultureInfo.InvariantCulture);
        var length = duration.ToString("0.######", CultureInfo.InvariantCulture);
        var info = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in new[] {
            "-y", "-i", input, "-ss", start, "-t", length,
            "-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            "-c:a", "aac", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output,
        }) info.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        try
        {
            if (!process.Start()) throw new InvalidOperationException("FFmpeg could not be started.");
            using var registration = cancellationToken.Register(() =>
            {
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            });
            var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
            while (await process.StandardOutput.ReadLineAsync(cancellationToken) is { } line)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!line.StartsWith("out_time_us=", StringComparison.Ordinal)) continue;
                if (long.TryParse(line.AsSpan("out_time_us=".Length), NumberStyles.Integer, CultureInfo.InvariantCulture, out var micros))
                    progress?.Report(Math.Clamp(micros / (duration * 1_000_000), 0, 0.99));
            }
            await process.WaitForExitAsync(cancellationToken);
            var error = await stderr;
            cancellationToken.ThrowIfCancellationRequested();
            if (process.ExitCode != 0 || !File.Exists(output) || new FileInfo(output).Length == 0)
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "FFmpeg could not create the trimmed video." : error.Trim());
            progress?.Report(1);
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            try { File.Delete(output); } catch (IOException) { }
            throw;
        }
    }

    private static string? FindFfmpeg()
    {
        var executable = OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg";
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory, executable);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
