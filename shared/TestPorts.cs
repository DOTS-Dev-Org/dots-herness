using System.Net;
using System.Net.Sockets;
using DotsHarnessCore;

/// <summary>
/// Loopback ports for fake providers in tests. Test classes run in parallel inside one process and
/// HttpListener shares its endpoint table per port, so "ask the OS for a free port, release it, bind
/// later" can hand two tests the same port. This never hands the same port out twice and retries when a
/// port turns out to be taken.
/// </summary>
internal static class TestPorts
{
    private static readonly object Gate = new();
    private static readonly HashSet<ushort> Issued = new();

    public static ushort Next()
    {
        lock (Gate)
        {
            for (var attempt = 0; attempt < 100; attempt++)
            {
                using var listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Start();
                var port = checked((ushort)((IPEndPoint)listener.LocalEndpoint).Port);
                if (Issued.Add(port)) return port;
            }
            throw new InvalidOperationException("No unused loopback port was available.");
        }
    }

    /// <summary>Starts a gateway on a fresh port, trying again if something else grabbed it first.</summary>
    public static NativeProviderGateway Start(Func<NativeGatewayRequest, Task<NativeGatewayResponse>> handler)
    {
        for (var attempt = 0; ; attempt++)
        {
            var gateway = new NativeProviderGateway(Next(), handler);
            try
            {
                gateway.Start();
                return gateway;
            }
            catch (Exception) when (attempt < 5)
            {
                try { gateway.Dispose(); } catch (Exception) { }
            }
        }
    }
}
