using System.Diagnostics;

namespace DotsHarnessCore;

public static class NativeClipboard
{
    public static void SetText(string text)
    {
        foreach (var (file, args) in new[] { ("wl-copy", ""), ("xclip", "-selection clipboard"), ("xsel", "--clipboard --input") })
        {
            try
            {
                using var process = Process.Start(new ProcessStartInfo(file, args) { RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true });
                if (process is null) continue;
                process.StandardInput.Write(text); process.StandardInput.Close();
                if (process.WaitForExit(1000)) return;
            }
            catch { }
        }
    }
}
