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
    bool Reasoning = false);

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
