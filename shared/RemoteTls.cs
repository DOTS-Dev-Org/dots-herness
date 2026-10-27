// Copyright (c) 2026 DOTS
// The remote-control gateway only speaks TLS. Its certificate is self-signed and
// long-lived; a phone trusts it by the SHA-256 fingerprint carried in the pairing
// QR code, never by a CA, so a LAN attacker cannot stand in for the desktop.

using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace DotsHarnessCore;

public static class RemoteTls
{
    public static X509Certificate2 LoadOrCreate(string root)
    {
        var file = Path.Combine(root, "remote-control-tls.pfx");
        if (File.Exists(file))
        {
            try
            {
                var saved = Load(File.ReadAllBytes(file));
                if (saved.HasPrivateKey && saved.NotAfter > DateTime.Now.AddDays(30)) return saved;
            }
            catch (CryptographicException) { }
        }

        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=HerNess Remote Control", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], false));
        using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
        var bytes = created.Export(X509ContentType.Pfx);
        Directory.CreateDirectory(root);
        // ponytail: the private key is protected by the per-user support directory
        // (plus 0600 on Unix), not a password; move it to DPAPI/libsecret if the
        // support directory ever becomes shared.
        File.WriteAllBytes(file, []);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.WriteAllBytes(file, bytes);
        // Re-load from PFX: SChannel cannot serve TLS with an ephemeral key.
        return Load(bytes);
    }

    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();

    private static X509Certificate2 Load(byte[] pfx) =>
        new(pfx, (string?)null, X509KeyStorageFlags.UserKeySet);
}
