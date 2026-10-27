// Copyright (c) 2026 DOTS
// Playing a generated audio file. The Windows shell plays it inline; both
// shells can hand it to the system's default player when inline playback is
// not available.

using System.Diagnostics;

namespace DotsHarnessCore;

public static class AudioPlayback
{
    /// <summary>Whether the file looks like something the shells can play.</summary>
    public static bool IsPlayable(string? path) =>
        !string.IsNullOrWhiteSpace(path)
        && Path.GetExtension(path).ToLowerInvariant() is ".mp3" or ".wav" or ".m4a" or ".aac" or ".flac" or ".ogg" or ".oga";

    /// <summary>
    /// Hands the file to the system's default player. Returns false when the
    /// system has none or the file is gone.
    /// </summary>
    public static bool OpenExternally(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return false;
        try
        {
            var info = new ProcessStartInfo
            {
                FileName = path,
                UseShellExecute = true,
            };
            if (!OperatingSystem.IsWindows()) info.FileName = "xdg-open";
            if (OperatingSystem.IsWindows()) info.Arguments = $"\"{path}\"";
            else info.ArgumentList.Add(path);
            using var process = Process.Start(info);
            return process is not null;
        }
        catch
        {
            return false;
        }
    }
}
