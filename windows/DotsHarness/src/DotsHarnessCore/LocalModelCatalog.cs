// Copyright (c) 2026 DOTS
// Curated GGUF catalog for one-click local LRM install.

namespace DotsHarnessCore;

public sealed record LocalModelSpec(
    string Id,
    string Name,
    string Family,
    string SizeLabel,
    int Context,
    string Filename,
    Uri Url,
    long Bytes,
    string Notes,
    bool Reasoning = false,
    string? Sha256 = null,
    // RAM or VRAM the model needs to run comfortably.
    int MinMemoryGb = 0,
    // A GGUF the user imported; it is served in place, never downloaded.
    string? LocalPath = null)
{
    public static LocalModelSpec Imported(string path)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        var bytes = File.Exists(path) ? new FileInfo(path).Length : 0;
        // ponytail: the trained context is inside the GGUF; llama-server reports
        // the served value through /props, which is what the router uses.
        return new LocalModelSpec(
            "gguf-" + name.ToLowerInvariant(), name, "GGUF", LocalModelCatalog.PrettyBytes(bytes), 32_768,
            Path.GetFileName(path), new Uri(Path.GetFullPath(path)), bytes, path, LocalPath: path);
    }
}

public static class LocalModelCatalog
{
    public static readonly IReadOnlyList<LocalModelSpec> Models = new[]
    {
        new LocalModelSpec(
            "qwen25-05b-q4",
            "Qwen2.5 0.5B Instruct",
            "Qwen",
            "0.5B · Q4_K_M · ~470 MB",
            8192,
            "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            new Uri("https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"),
            491_400_032,
            "Smallest chat model. Fine for a first local try."),
        new LocalModelSpec(
            "llama32-1b-q4",
            "Llama 3.2 1B Instruct",
            "Llama",
            "1B · Q4_K_M · ~770 MB",
            8192,
            "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            new Uri("https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
            807_694_464,
            "Better English chat than 0.5B, still laptop-friendly."),
        new LocalModelSpec(
            "dsr1-15b-q4",
            "DeepSeek R1 Distill 1.5B",
            "DeepSeek",
            "1.5B · Q4_K_M · ~1.0 GB",
            16_384,
            "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf",
            new Uri("https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"),
            1_117_320_800,
            "Local reasoning model (LRM). Slower, thinks before answering.",
            Reasoning: true),
        new LocalModelSpec(
            "qwen3-4b-q4",
            "Qwen3 4B Instruct",
            "Qwen",
            "4B · Q4_K_M · ~2.5 GB",
            32_768,
            "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            new Uri("https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
            2_497_281_120,
            "Needs about 4 GB of GPU memory or RAM.",
            Sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            MinMemoryGb: 4),
        new LocalModelSpec(
            "qwen25-coder-7b-q4",
            "Qwen2.5 Coder 7B",
            "Qwen",
            "7B · Q4_K_M · ~4.7 GB",
            32_768,
            "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
            new Uri("https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"),
            4_683_074_336,
            "Needs about 8 GB of GPU memory or RAM.",
            Sha256: "1664fccab734674a50763490a8c6931b70e3f2f8ec10031b54806d30e5f956b6",
            MinMemoryGb: 8),
        new LocalModelSpec(
            "qwen25-coder-14b-q4",
            "Qwen2.5 Coder 14B",
            "Qwen",
            "14B · Q4_K_M · ~9.0 GB",
            32_768,
            "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf",
            new Uri("https://huggingface.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"),
            8_988_111_072,
            "Needs about 12 GB of GPU memory or RAM.",
            Sha256: "2946d28c9e1bb2bcae6d42e8678863a31775df6f740315c7d7e6d6b6411f5937",
            MinMemoryGb: 12),
        new LocalModelSpec(
            "gpt-oss-20b-q4",
            "gpt-oss 20B",
            "OpenAI",
            "20B · Q4_K_M · ~11.6 GB",
            131_072,
            "gpt-oss-20b-Q4_K_M.gguf",
            new Uri("https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf"),
            11_624_759_488,
            "Needs about 16 GB of GPU memory or RAM.",
            Reasoning: true,
            Sha256: "c27536640e410032865dc68781d80a08b98f8db5e93575919af8ccc0568aeb4f",
            MinMemoryGb: 16),
    };

    public static LocalModelSpec? Spec(string id) => Models.FirstOrDefault(m => m.Id == id);

    public static string PrettyBytes(long value)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double size = value;
        var unit = 0;
        while (size >= 1024 && unit < units.Length - 1)
        {
            size /= 1024;
            unit++;
        }
        return $"{size:0.#} {units[unit]}";
    }
}
