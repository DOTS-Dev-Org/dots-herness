// Copyright (c) 2026 DOTS
// Curated GGUF catalog for one-click local LRM install.

import Foundation

/// Which bundled server runs a model: llama.cpp (GGUF, every GPU vendor) or
/// MLX (Apple Silicon only).
public enum LocalEngine: String, Sendable, Codable {
    case llama
    case mlx
}

public struct LocalModelSpec: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var family: String
    public var sizeLabel: String
    public var context: Int
    public var filename: String
    public var url: URL
    public var bytes: Int64
    public var notes: String
    public var reasoning: Bool
    public var engine: LocalEngine
    public var sha256: String?
    /// Hugging Face repository for MLX models, which are a directory of files.
    public var repo: String?
    /// RAM (CPU, Apple Silicon) or VRAM the model needs to run comfortably.
    public var minMemoryGB: Int
    /// A GGUF the user imported; it is served in place, never downloaded.
    public var localPath: String?

    public init(
        id: String,
        name: String,
        family: String,
        sizeLabel: String,
        context: Int,
        filename: String,
        url: URL,
        bytes: Int64,
        notes: String,
        reasoning: Bool = false,
        engine: LocalEngine = .llama,
        sha256: String? = nil,
        repo: String? = nil,
        minMemoryGB: Int = 0,
        localPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.sizeLabel = sizeLabel
        self.context = context
        self.filename = filename
        self.url = url
        self.bytes = bytes
        self.notes = notes
        self.reasoning = reasoning
        self.engine = engine
        self.sha256 = sha256
        self.repo = repo
        self.minMemoryGB = minMemoryGB
        self.localPath = localPath
    }

    /// A GGUF file the user picked from disk.
    public static func imported(path: String) -> LocalModelSpec {
        let file = URL(fileURLWithPath: path)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return LocalModelSpec(
            id: "gguf-" + file.deletingPathExtension().lastPathComponent.lowercased(),
            name: file.deletingPathExtension().lastPathComponent,
            family: "GGUF",
            sizeLabel: LocalModelCatalog.prettyBytes(bytes),
            // ponytail: the trained context is inside the GGUF; llama-server reports
            // the served value through /props, which is what the router uses.
            context: 32_768,
            filename: file.lastPathComponent,
            url: file,
            bytes: bytes,
            notes: path,
            localPath: path
        )
    }
}

public enum LocalModelCatalog {
    public static let models: [LocalModelSpec] = [
        LocalModelSpec(
            id: "qwen25-05b-q4",
            name: "Qwen2.5 0.5B Instruct",
            family: "Qwen",
            sizeLabel: "0.5B · Q4_K_M · ~470 MB",
            context: 8_192,
            filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
            bytes: 491_400_032,
            notes: AppCopy.text("localModel.qwenNote")
        ),
        LocalModelSpec(
            id: "llama32-1b-q4",
            name: "Llama 3.2 1B Instruct",
            family: "Llama",
            sizeLabel: "1B · Q4_K_M · ~770 MB",
            context: 8_192,
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            bytes: 807_694_464,
            notes: AppCopy.text("localModel.llamaNote")
        ),
        LocalModelSpec(
            id: "dsr1-15b-q4",
            name: "DeepSeek R1 Distill 1.5B",
            family: "DeepSeek",
            sizeLabel: "1.5B · Q4_K_M · ~1.0 GB",
            context: 16_384,
            filename: "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf")!,
            bytes: 1_117_320_800,
            notes: AppCopy.text("localModel.deepSeekNote"),
            reasoning: true
        ),
        LocalModelSpec(
            id: "qwen3-4b-q4",
            name: "Qwen3 4B Instruct",
            family: "Qwen",
            sizeLabel: "4B · Q4_K_M · ~2.5 GB",
            context: 32_768,
            filename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            bytes: 2_497_281_120,
            notes: AppCopy.format("localModel.needsMemory", 4),
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            minMemoryGB: 4
        ),
        LocalModelSpec(
            id: "qwen25-coder-7b-q4",
            name: "Qwen2.5 Coder 7B",
            family: "Qwen",
            sizeLabel: "7B · Q4_K_M · ~4.7 GB",
            context: 32_768,
            filename: "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf")!,
            bytes: 4_683_074_336,
            notes: AppCopy.format("localModel.needsMemory", 8),
            sha256: "1664fccab734674a50763490a8c6931b70e3f2f8ec10031b54806d30e5f956b6",
            minMemoryGB: 8
        ),
        LocalModelSpec(
            id: "qwen25-coder-14b-q4",
            name: "Qwen2.5 Coder 14B",
            family: "Qwen",
            sizeLabel: "14B · Q4_K_M · ~9.0 GB",
            context: 32_768,
            filename: "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf")!,
            bytes: 8_988_111_072,
            notes: AppCopy.format("localModel.needsMemory", 12),
            sha256: "2946d28c9e1bb2bcae6d42e8678863a31775df6f740315c7d7e6d6b6411f5937",
            minMemoryGB: 12
        ),
        LocalModelSpec(
            id: "gpt-oss-20b-q4",
            name: "gpt-oss 20B",
            family: "OpenAI",
            sizeLabel: "20B · Q4_K_M · ~11.6 GB",
            context: 131_072,
            filename: "gpt-oss-20b-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf")!,
            bytes: 11_624_759_488,
            notes: AppCopy.format("localModel.needsMemory", 16),
            reasoning: true,
            sha256: "c27536640e410032865dc68781d80a08b98f8db5e93575919af8ccc0568aeb4f",
            minMemoryGB: 16
        ),
    ]

    /// MLX builds, served by `mlx_lm` on Apple Silicon. `bytes` is the whole
    /// repository; the file list is read from Hugging Face at download time.
    public static let mlxModels: [LocalModelSpec] = [
        mlx(id: "mlx-qwen25-05b-4bit", name: "Qwen2.5 0.5B Instruct", size: "0.5B · 4-bit · ~290 MB",
            repo: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", bytes: 289_601_064, memory: 2),
        mlx(id: "mlx-qwen3-4b-4bit", name: "Qwen3 4B Instruct", size: "4B · 4-bit · ~2.3 GB",
            repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", bytes: 2_278_972_236, memory: 8),
        mlx(id: "mlx-qwen25-coder-7b-4bit", name: "Qwen2.5 Coder 7B", size: "7B · 4-bit · ~4.3 GB",
            repo: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", bytes: 4_295_890_004, memory: 16),
        mlx(id: "mlx-qwen25-coder-14b-4bit", name: "Qwen2.5 Coder 14B", size: "14B · 4-bit · ~8.3 GB",
            repo: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit", bytes: 8_321_093_967, memory: 24),
    ]

    private static func mlx(id: String, name: String, size: String, repo: String, bytes: Int64, memory: Int) -> LocalModelSpec {
        LocalModelSpec(
            id: id, name: name, family: "MLX", sizeLabel: size, context: 32_768,
            filename: repo.replacingOccurrences(of: "/", with: "--"),
            url: URL(string: "https://huggingface.co/\(repo)")!,
            bytes: bytes,
            notes: AppCopy.format("localModel.needsMemory", memory),
            engine: .mlx, repo: repo, minMemoryGB: memory
        )
    }

    public static func spec(id: String) -> LocalModelSpec? {
        (models + mlxModels).first { $0.id == id }
    }

    public static func prettyBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
