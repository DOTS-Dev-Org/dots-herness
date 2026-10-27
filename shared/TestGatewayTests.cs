// Copyright (c) 2026 DOTS
// A local provider for the test suites. The file name ends in "Tests.cs" so it
// stays out of the production build; the shared project compiles every other
// shared file into the shipped app.

using System.Net;
using System.Net.Sockets;
using DotsHarnessCore;

public static class LocalTestGateway
{
    private static readonly object Gate = new();

    /// <summary>
    /// A started gateway on a free port. The port is taken and bound under one
    /// lock, so two tests running in parallel never pick the same one.
    /// </summary>
    public static NativeProviderGateway Start(Func<NativeGatewayRequest, Task<NativeGatewayResponse>> handler)
    {
        lock (Gate)
        {
            var gateway = new NativeProviderGateway(FreePort(), handler);
            gateway.Start();
            return gateway;
        }
    }

    private static ushort FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return checked((ushort)((IPEndPoint)listener.LocalEndpoint).Port);
    }
}
