// Copyright (c) 2026 DOTS
// Optional local OCR for Windows/Linux. Image bytes stay on the device.

using System.Diagnostics;

namespace DotsHarnessCore;

public static class MediaOcr
{
    public static async Task<string> RecognizeLocallyAsync(string imagePath, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(imagePath)) throw new FileNotFoundException("The image is missing.", imagePath);
        var executable = Environment.GetEnvironmentVariable("TESSERACT_CMD");
        if (string.IsNullOrWhiteSpace(executable) || !File.Exists(executable)) executable = FindOnPath("tesseract");
        if (executable is null)
            throw new FileNotFoundException(LocalizationService.Current.Get("library.ocrUnavailable"));

        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add(imagePath);
        start.ArgumentList.Add("stdout");
        start.ArgumentList.Add("-l");
        start.ArgumentList.Add("eng+tur");
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Tesseract could not be started.");
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        });
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var text = await output;
        var diagnostic = await error;
        cancellationToken.ThrowIfCancellationRequested();
        if (process.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(diagnostic) ? "Local OCR failed." : diagnostic.Trim());
        return text.Trim();
    }

    private static string? FindOnPath(string name)
    {
        var executableName = OperatingSystem.IsWindows() ? name + ".exe" : name;
        return (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(folder => Path.Combine(folder, executableName))
            .FirstOrDefault(File.Exists);
    }
}
