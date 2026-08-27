using System.Diagnostics;

namespace DotsHarnessCore;

public static class NativeClipboard
{
    public static void SetText(string text)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("clip.exe") { RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true });
            if (process is null) return;
            process.StandardInput.Write(text);
            process.StandardInput.Close();
            process.WaitForExit(1000);
        }
        catch { }
    }
}
