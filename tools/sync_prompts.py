#!/usr/bin/env python3
"""Write the canonical HerNess prompt text into every platform's source file.

The text lives in shared/prompts/*.txt. Each platform keeps a literal so nothing
has to be bundled or loaded at runtime; this script is what keeps those literals
identical. Run it after editing a canonical file:

    python3 tools/sync_prompts.py            # rewrite the literals
    python3 tools/sync_prompts.py --check    # fail if any literal is stale

Platform-specific text (mobile's "On this device", self-verification, the
platform tool-use block) is deliberately not synced and stays in its own file.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPTS = ROOT / "shared" / "prompts"

# (file, canonical prompt, opening anchor, closing anchor, indent, placeholder map)
TARGETS = [
    (
        "macos/DotsHarness/Sources/DotsHarnessCore/HerNessPrompt.swift",
        "core.txt",
        'public static func core(scope: String, toolGuidance: String) -> String {\n        """\n',
        '\n        """',
        8,
        {"SCOPE": r"\(scope)", "TOOL_GUIDANCE": r"\(toolGuidance)"},
    ),
    (
        "macos/DotsHarness/Sources/DotsHarnessCore/HerNessPrompt.swift",
        "plan-mode.txt",
        'public static func planMode(tools: [String]) -> String {\n        """\n',
        '\n        """',
        8,
        {"TOOLS": r'\(tools.joined(separator: ", "))'},
    ),
    (
        "mobile/ios/Sources/HerNessPrompt.swift",
        "core.txt",
        'static func core(scope: String, toolGuidance: String) -> String {\n        """\n',
        '\n        """',
        8,
        {"SCOPE": r"\(scope)", "TOOL_GUIDANCE": r"\(toolGuidance)"},
    ),
    (
        "shared/HerNessPrompt.cs",
        "core.txt",
        'public static string Core(string scope, string toolGuidance) => $"""\n',
        '\n        """;',
        8,
        {"SCOPE": "{scope}", "TOOL_GUIDANCE": "{toolGuidance}"},
    ),
    (
        "shared/HerNessPrompt.cs",
        "plan-mode.txt",
        'public static string PlanMode(IEnumerable<string> tools) => $"""\n',
        '\n        """;',
        8,
        {"TOOLS": '{string.Join(", ", tools)}'},
    ),
    (
        "mobile/android/app/src/main/java/com/dots/herness/mobile/HerNessPrompt.kt",
        "core.txt",
        'fun core(scope: String, toolGuidance: String): String = """\n',
        '\n"""',
        0,
        {"SCOPE": "$scope", "TOOL_GUIDANCE": "$toolGuidance"},
    ),
]


def render(prompt: str, indent: int, placeholders: dict[str, str]) -> str:
    for name, value in placeholders.items():
        prompt = prompt.replace("{" + name + "}", value)
    pad = " " * indent
    return "\n".join(pad + line if line else "" for line in prompt.rstrip("\n").split("\n"))


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for path, prompt_name, start, end, indent, placeholders in TARGETS:
        file = ROOT / path
        source = file.read_text()
        body = render((PROMPTS / prompt_name).read_text(), indent, placeholders)
        begin = source.index(start) + len(start)
        finish = source.index(end, begin)
        if source[begin:finish] == body:
            continue
        stale.append(f"{path} ({prompt_name})")
        if not check:
            file.write_text(source[:begin] + body + source[finish:])

    if not stale:
        print("prompts in sync")
        return 0
    if check:
        print("stale prompt literals:\n  " + "\n  ".join(stale))
        print("run: python3 tools/sync_prompts.py")
        return 1
    print("updated:\n  " + "\n  ".join(stale))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
