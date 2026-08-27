// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Loader;

namespace HarnessPluginKit;

/// <summary>
/// Native / managed ABI for compiled user assemblies. Keep this table tiny
/// and append-only.
///
/// A compiled plugin may be either:
/// <list type="bullet">
/// <item>A managed assembly that exports a public <see cref="IHarnessPlugin"/> type
/// with a parameterless constructor (preferred on Linux).</item>
/// <item>A native shared object that exports the same C symbols as the macOS dylib ABI:
/// <c>harness_plugin_abi_version</c>, <c>harness_plugin_id</c>,
/// <c>harness_plugin_make</c>.</item>
/// </list>
/// </summary>
public static class PluginAbi
{
    public const string Version = PluginManifest.CurrentAbi;
    public const string AbiSymbol = "harness_plugin_abi_version";
    public const string IdSymbol = "harness_plugin_id";
    public const string MakeSymbol = "harness_plugin_make";
}

public static class PluginLibrary
{
    public static IHarnessPlugin Load(string path)
    {
        if (!File.Exists(path))
        {
            throw PluginException.ApplyFailed($"missing library {path}");
        }

        if (LooksManaged(path))
        {
            return LoadManaged(path);
        }

        return LoadNative(path);
    }

    private static bool LooksManaged(string path)
    {
        try
        {
            AssemblyName.GetAssemblyName(path);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static IHarnessPlugin LoadManaged(string path)
    {
        var alc = new PluginLoadContext(path);
        Assembly assembly;
        try
        {
            assembly = alc.LoadFromAssemblyPath(Path.GetFullPath(path));
        }
        catch (Exception ex)
        {
            throw PluginException.ApplyFailed(ex.Message);
        }

        var type = assembly.GetTypes().FirstOrDefault(t =>
            typeof(IHarnessPlugin).IsAssignableFrom(t) && !t.IsAbstract && t.GetConstructor(Type.EmptyTypes) is not null);
        if (type is null)
        {
            throw PluginException.ApplyFailed("assembly has no IHarnessPlugin with a public parameterless constructor");
        }

        if (Activator.CreateInstance(type) is not IHarnessPlugin plugin)
        {
            throw PluginException.ApplyFailed("plugin factory returned nil");
        }

        if (!plugin.Manifest.AbiCompatible)
        {
            throw PluginException.IncompatibleAbi(plugin.Manifest.Abi);
        }

        return plugin;
    }

    private static IHarnessPlugin LoadNative(string path)
    {
        if (!NativeLibrary.TryLoad(path, out var handle))
        {
            throw PluginException.ApplyFailed($"dlopen failed for {path}");
        }

        try
        {
            if (!NativeLibrary.TryGetExport(handle, PluginAbi.AbiSymbol, out var abiPtr)
                || !NativeLibrary.TryGetExport(handle, PluginAbi.IdSymbol, out var idPtr)
                || !NativeLibrary.TryGetExport(handle, PluginAbi.MakeSymbol, out var makePtr))
            {
                NativeLibrary.Free(handle);
                throw PluginException.ApplyFailed("missing ABI export");
            }

            var abiFn = Marshal.GetDelegateForFunctionPointer<CStringFn>(abiPtr);
            var makeFn = Marshal.GetDelegateForFunctionPointer<MakeFn>(makePtr);
            var abi = Marshal.PtrToStringUTF8(abiFn()) ?? "";
            _ = Marshal.PtrToStringUTF8(Marshal.GetDelegateForFunctionPointer<CStringFn>(idPtr)());
            if (!SemVer.TryParse(abi, out var have)
                || !SemVer.TryParse(PluginAbi.Version, out var want)
                || have.Major != want.Major)
            {
                NativeLibrary.Free(handle);
                throw PluginException.IncompatibleAbi(abi);
            }

            var raw = makeFn();
            if (raw == IntPtr.Zero)
            {
                NativeLibrary.Free(handle);
                throw PluginException.ApplyFailed("plugin factory returned nil");
            }

            var handleRef = GCHandle.FromIntPtr(raw);
            if (handleRef.Target is not IHarnessPlugin plugin)
            {
                NativeLibrary.Free(handle);
                throw PluginException.ApplyFailed("native factory did not return IHarnessPlugin");
            }
            return plugin;
        }
        catch (PluginException)
        {
            throw;
        }
        catch (Exception ex)
        {
            NativeLibrary.Free(handle);
            throw PluginException.ApplyFailed(ex.Message);
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr CStringFn();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr MakeFn();

    private sealed class PluginLoadContext : AssemblyLoadContext
    {
        private readonly AssemblyDependencyResolver _resolver;

        public PluginLoadContext(string path) : base(isCollectible: false)
        {
            _resolver = new AssemblyDependencyResolver(path);
        }

        protected override Assembly? Load(AssemblyName assemblyName)
        {
            if (assemblyName.Name is "HarnessPluginKit" or "PluginRuntime" or "DotsHarnessCore")
            {
                return null;
            }
            var path = _resolver.ResolveAssemblyToPath(assemblyName);
            return path is null ? null : LoadFromAssemblyPath(path);
        }
    }
}
