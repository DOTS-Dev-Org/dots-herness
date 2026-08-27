// Copyright (c) 2026 DOTS
// HTTP download for local runtimes, model files, and explicitly enabled sharing.

using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace DotsHarnessCore;

public static class FileDownloader
{
    public readonly record struct Progress(long Received, long Expected)
    {
        public double Fraction => Expected > 0 ? Math.Min(1, (double)Received / Expected) : 0;
    }

    public static async Task DownloadAsync(
        Uri remote,
        string destination,
        long expected = 0,
        Action<Progress>? progress = null,
        CancellationToken ct = default,
        string? sha256 = null)
    {
        var directory = Path.GetDirectoryName(destination);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        if (File.Exists(destination))
        {
            var size = new FileInfo(destination).Length;
            if (Matches(destination, expected, sha256))
            {
                progress?.Invoke(new Progress(size, Math.Max(expected, size)));
                return;
            }
            File.Delete(destination);
        }

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        using var request = new HttpRequestMessage(HttpMethod.Get, remote);
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        var part = destination + ".part";
        var offset = File.Exists(part) ? new FileInfo(part).Length : 0;
        if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!response.IsSuccessStatusCode)
        {
            throw new RouterException($"Download failed (HTTP {(int)response.StatusCode})");
        }
        var append = offset > 0 && response.StatusCode == HttpStatusCode.PartialContent;
        if (!append) offset = 0;
        var total = response.Content.Headers.ContentLength is { } length ? length + offset : expected;
        progress?.Invoke(new Progress(offset, total));
        await using (var input = await response.Content.ReadAsStreamAsync(ct))
        await using (var output = new FileStream(part, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 128 * 1024, useAsync: true))
        {
            var buffer = new byte[1024 * 128];
            long received = offset;
            int read;
            while ((read = await input.ReadAsync(buffer, ct)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read), ct);
                received += read;
                progress?.Invoke(new Progress(received, total));
            }
        }
        File.Move(part, destination, overwrite: true);
        if (!Matches(destination, expected, sha256))
        {
            File.Delete(destination);
            throw new RouterException(sha256 is null ? "Downloaded file size does not match the expected size." : "Downloaded file checksum does not match.");
        }
        var finalSize = new FileInfo(destination).Length;
        progress?.Invoke(new Progress(finalSize, Math.Max(expected, finalSize)));
    }

    private static bool Matches(string path, long expected, string? sha256)
    {
        var size = new FileInfo(path).Length;
        if (sha256 is not null)
        {
            using var stream = File.OpenRead(path);
            var actual = Convert.ToHexString(SHA256.HashData(stream));
            return actual.Equals(Normalize(sha256), StringComparison.OrdinalIgnoreCase);
        }
        return expected == 0 || size >= Math.Max(1, expected / 2);
    }

    private static string Normalize(string value) => value.Replace("sha256:", "", StringComparison.OrdinalIgnoreCase).Trim().ToUpperInvariant();
}
