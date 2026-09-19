#!/usr/bin/env python3
"""Generate native plugin source from the shared DOTS plugin IR.

The generator intentionally emits only the common, typed surface. It never
translates arbitrary SwiftUI or executes plugin code. Platform-specific source
can be added under the generated source directories before publishing.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path


PLATFORMS = ("macos", "windows", "linux")
PANEL_SLOTS = {
    "conversation.composer.accessory",
    "shell.overlay",
    "settings.sections",
    "plugins.detail",
    "shell.sidebar.footer",
}
VALUE_TYPES = {"string", "number", "boolean", "object", "array"}


def fail(message: str) -> None:
    raise SystemExit(f"generate_native_plugin: {message}")


def identifier(raw: str) -> str:
    value = re.sub(r"[^A-Za-z0-9]+", "_", raw).strip("_")
    if not value:
        fail("plugin id cannot produce an empty identifier")
    if value[0].isdigit():
        value = "Plugin_" + value
    return value[:80]


def load_ir(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid IR: {exc}")
    if not isinstance(value, dict) or value.get("version") != 1:
        fail("plugin.ir.json must be an object with version 1")
    allowed = {"version", "prompt", "tools", "events", "settings", "panels"}
    unknown = sorted(set(value) - allowed)
    if unknown:
        fail(f"IR has unsupported keys: {', '.join(unknown)}")
    for key in ("prompt", "tools", "events", "settings", "panels"):
        if not isinstance(value.get(key, []), list):
            fail(f"IR field {key} must be an array")
    for item in value["prompt"]:
        if not isinstance(item, dict) or not {"name", "order", "text"} <= set(item):
            fail("every prompt entry needs name, order, and text")
    for item in value["tools"]:
        if not isinstance(item, dict) or not {"name", "description", "parameters"} <= set(item):
            fail("every tool needs name, description, and parameters")
        if not isinstance(item["parameters"], list):
            fail("tool parameters must be arrays")
        for parameter in item["parameters"]:
            if not isinstance(parameter, dict) or parameter.get("type") not in VALUE_TYPES:
                fail("tool parameter types must be string, number, boolean, object, or array")
    for item in value["events"]:
        if not isinstance(item, dict) or item.get("direction", "both") not in {"listen", "emit", "both"}:
            fail("event direction must be listen, emit, or both")
    for item in value["settings"]:
        if not isinstance(item, dict) or item.get("type") not in VALUE_TYPES or "key" not in item:
            fail("settings need key and a supported type")
    for item in value["panels"]:
        if not isinstance(item, dict) or item.get("slot") not in PANEL_SLOTS or "body" not in item:
            fail("panels need a supported slot and body")
    return value


def manifest_values(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read plugin.yml: {exc}")
    values: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"^(id|name|version|plane|runtime|library):\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2).strip().strip('"\'')
    required = {"id", "name", "version", "plane", "runtime", "library"}
    missing = sorted(required - values.keys())
    if missing:
        fail(f"plugin.yml is missing: {', '.join(missing)}")
    if values["runtime"].lower() != "native":
        fail("plugin.yml runtime must be native")
    if values["plane"] not in {"host", "session"}:
        fail("plugin.yml plane must be host or session")
    library = values["library"]
    if (
        not library
        or library.startswith("/")
        or "\\" in library
        or "\x00" in library
        or any(part in {"", ".", ".."} for part in library.split("/"))
    ):
        fail("plugin.yml library must be a safe relative path")
    if not re.fullmatch(r"\d+\.\d+\.\d+", values["version"]):
        fail("plugin.yml version must be SemVer")
    return values


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def csharp_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def library_stem(value: str) -> str:
    name = Path(value).name
    for suffix in (".dylib", ".dll", ".so"):
        if name.lower().endswith(suffix):
            name = name[: -len(suffix)]
            break
    if name.startswith("lib"):
        name = name[3:]
    return identifier(name or "Plugin")


def swift_source(meta: dict[str, str], ir: dict, class_name: str) -> str:
    prompts = "\n".join(
        f'        ctx.prompt.section(name: {swift_string(item["name"])}, order: {int(item["order"])}, text: {swift_string(item["text"])})'
        for item in ir["prompt"]
    )
    tools = []
    for item in ir["tools"]:
        parameters = ", ".join(
            f'ToolParameter(name: {swift_string(p["name"])}, type: {swift_string(p["type"])}, description: {swift_string(p.get("description", ""))}, required: {str(bool(p.get("required", True))).lower()})'
            for p in item["parameters"]
        )
        tools.append(
            f'''        ctx.tools.register(
            name: {swift_string(item["name"])},
            description: {swift_string(item.get("description", ""))},
            parameters: [{parameters}]
        ) {{ _ in
            "IR tool {item["name"]} requires native implementation"
        }}'''
        )
    body = "\n".join(part for part in (prompts, "\n".join(tools)) if part)
    return f'''import Foundation
import HarnessPluginKit

public final class {class_name}: HarnessPlugin {{
    public static let manifest = PluginManifest(
        id: {swift_string(meta["id"])},
        name: {swift_string(meta["name"])},
        version: {swift_string(meta["version"])},
        plane: .{meta["plane"]},
        library: {swift_string(meta["library"])},
        runtime: "native"
    )

    public init() {{}}

    @MainActor
    public func apply(_ ctx: PluginContext) throws {{
{body or "        // Add platform-specific native behavior here."}
        // Events, settings, and supported panel nodes remain in plugin.ir.json.
        // Arbitrary SwiftUI is intentionally not translated by this generator.
    }}
}}

// Stable native factory ABI. The host validates all three exports before it
// calls the retained factory result.
@_cdecl("harness_plugin_abi_version")
public func harness_plugin_abi_version() -> UnsafePointer<CChar> {{ GeneratedPluginCString.abi }}
@_cdecl("harness_plugin_id")
public func harness_plugin_id() -> UnsafePointer<CChar> {{ GeneratedPluginCString.id }}
@_cdecl("harness_plugin_make")
public func harness_plugin_make() -> UnsafeMutableRawPointer {{
    Unmanaged.passRetained({class_name}()).toOpaque()
}}

private enum GeneratedPluginCString {{
    nonisolated(unsafe) static let abi = UnsafePointer(strdup("1.0.0")!)
    nonisolated(unsafe) static let id = UnsafePointer(strdup({swift_string(meta["id"])} )!)
}}
'''


def csharp_source(meta: dict[str, str], ir: dict, class_name: str) -> str:
    prompts = "\n".join(
        f'        ctx.Prompt.Section({csharp_string(item["name"])}, {int(item["order"])}, {csharp_string(item["text"])})();'
        for item in ir["prompt"]
    )
    tools = []
    for item in ir["tools"]:
        parameters = ", ".join(
            f'new ToolParameter({csharp_string(p["name"])}, {csharp_string(p["type"])}, {csharp_string(p.get("description", ""))}, {str(bool(p.get("required", True))).lower()})'
            for p in item["parameters"]
        )
        tools.append(
            f'''        ctx.Tools.Register(
            {csharp_string(item["name"])},
            {csharp_string(item.get("description", ""))},
            new ToolParameter[] {{ {parameters} }},
            _ => Task.FromResult("IR tool {item["name"]} requires native implementation"))();'''
        )
    body = "\n".join(part for part in (prompts, "\n".join(tools)) if part)
    return f'''using System.Threading.Tasks;
using HarnessPluginKit;

namespace GeneratedPlugin;

public sealed class {class_name} : IDefaultPlugin
{{
    public PluginManifest Manifest => new(
        {csharp_string(meta["id"])},
        {csharp_string(meta["name"])},
        {csharp_string(meta["version"])},
        PluginPlane.{meta["plane"].capitalize()},
        Library: {csharp_string(meta["library"])},
        Runtime: "native");

    public void Apply(IPluginContext ctx)
    {{
{body or "        // Add platform-specific native behavior here."}
        // Events, settings, and supported panel nodes remain in plugin.ir.json.
        // Arbitrary WPF/Avalonia UI is intentionally not translated by this generator.
    }}
}}
'''


def write_outputs(args: argparse.Namespace, meta: dict[str, str], ir: dict) -> None:
    destination = args.output.resolve()
    if destination.exists() and any(destination.iterdir()) and not args.force:
        fail(f"output is not empty: {destination} (use --force to replace generated files)")
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.manifest, destination / "plugin.yml")
    shutil.copy2(args.ir, destination / "plugin.ir.json")
    shutil.copy2(args.license, destination / "license")
    (destination / "source" / "macos" / "Sources" / "GeneratedPlugin").mkdir(parents=True, exist_ok=True)
    (destination / "source" / "windows").mkdir(parents=True, exist_ok=True)
    (destination / "source" / "linux").mkdir(parents=True, exist_ok=True)
    name = identifier(meta["id"])
    (destination / "source" / "macos" / "Sources" / "GeneratedPlugin" / f"{name}Plugin.swift").write_text(
        swift_source(meta, ir, f"{name}Plugin"), encoding="utf-8"
    )
    for platform in ("windows", "linux"):
        root = destination / "source" / platform
        (root / f"{name}Plugin.cs").write_text(csharp_source(meta, ir, f"{name}Plugin"), encoding="utf-8")
        (root / f"{name}Plugin.csproj").write_text(
            f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <EnableDefaultCompileItems>true</EnableDefaultCompileItems>
    <AssemblyName>{library_stem(meta["library"])}</AssemblyName>
  </PropertyGroup>
  <!-- Set HarnessPluginSdk to a checked-out HarnessPluginKit SDK before CI. -->
  <ItemGroup Condition="'$(HarnessPluginSdk)' != ''">
    <ProjectReference Include="$(HarnessPluginSdk)/HarnessPluginKit/HarnessPluginKit.csproj" />
  </ItemGroup>
</Project>
''', encoding="utf-8"
        )
    (destination / "source" / "macos" / "Package.swift").write_text(
        f'''// Generated native plugin package. CI sets HARNESS_PLUGIN_SDK to the
// checked-out DotsHarness package; the untrusted source never receives app
// signing keys or Marketplace secrets.
import Foundation
import PackageDescription

let harnessSDKPath = ProcessInfo.processInfo.environment["HARNESS_PLUGIN_SDK"]
let dependencies: [Package.Dependency] = harnessSDKPath.map {{ [.package(path: $0)] }} ?? []
let targetDependencies: [Target.Dependency] = harnessSDKPath.map {{
    [.product(name: "HarnessPluginKit", package: "DotsHarness")]
}} ?? []

let package = Package(
    name: "{name}Plugin",
    products: [.library(name: "{library_stem(meta["library"])}", type: .dynamic, targets: ["GeneratedPlugin"])],
    dependencies: dependencies,
    targets: [.target(name: "GeneratedPlugin", dependencies: targetDependencies, path: "Sources/GeneratedPlugin")]
)
''', encoding="utf-8"
    )
    for platform, architecture in (("macos", "arm64"), ("macos", "x64"), ("windows", "x64"), ("linux", "x64")):
        (destination / "artifacts" / platform / architecture).mkdir(parents=True, exist_ok=True)
    (destination / "GENERATOR.md").write_text(
        "Generated from plugin.ir.json. The CI job rewrites the library extension per target and packages the compiled native output. Add the HarnessPlugin SDK reference and implement platform-specific behavior before publishing.\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--ir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--license", type=Path, required=True, help="license file copied into the publishable package")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if not args.manifest.is_file() or not args.ir.is_file() or not args.license.is_file():
        fail("--manifest, --ir, and --license must be files")
    if args.license.stat().st_size == 0:
        fail("--license must not be empty")
    meta = manifest_values(args.manifest)
    ir = load_ir(args.ir)
    write_outputs(args, meta, ir)
    print(f"generated native plugin draft at {args.output}")


if __name__ == "__main__":
    main()
