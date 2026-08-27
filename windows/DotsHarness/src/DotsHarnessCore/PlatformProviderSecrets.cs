using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

public sealed class PlatformProviderSecrets : IProviderSecretStore
{
    private readonly string _root;
    public PlatformProviderSecrets(string root) { _root = Path.Combine(root, "provider-secrets"); Directory.CreateDirectory(_root); }

    public string? Read(string id)
    {
        var path = PathFor(id);
        if (!File.Exists(path)) return null;
        try { return Encoding.UTF8.GetString(Unprotect(File.ReadAllBytes(path))); }
        catch { return null; }
    }

    public void Write(string id, string value) => File.WriteAllBytes(PathFor(id), Protect(Encoding.UTF8.GetBytes(value)));
    public void Delete(string id) { try { File.Delete(PathFor(id)); } catch { } }

    private string PathFor(string id) => Path.Combine(_root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).ToLowerInvariant());

    private static byte[] Protect(byte[] data)
    {
        var input = new Blob(data);
        var output = new Blob();
        if (!CryptProtectData(ref input, "DotsHarness provider credential", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref output)) throw new CryptographicException(Marshal.GetLastWin32Error());
        return output.ToArray();
    }

    private static byte[] Unprotect(byte[] data)
    {
        var input = new Blob(data);
        var output = new Blob();
        if (!CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref output)) throw new CryptographicException(Marshal.GetLastWin32Error());
        return output.ToArray();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Blob
    {
        public int Length;
        public IntPtr Data;
        public Blob(byte[] data) { Length = data.Length; Data = Marshal.AllocHGlobal(data.Length); Marshal.Copy(data, 0, Data, data.Length); }
        public byte[] ToArray() { var value = new byte[Length]; if (Length > 0) Marshal.Copy(Data, value, 0, Length); Marshal.FreeHGlobal(Data); return value; }
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CryptProtectData(ref Blob dataIn, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, ref Blob dataOut);
    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob dataIn, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, ref Blob dataOut);
}
