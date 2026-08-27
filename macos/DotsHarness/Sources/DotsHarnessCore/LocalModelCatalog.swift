// Copyright (c) 2026 DOTS
// Curated GGUF catalog for one-click local LRM install.

import Foundation

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
        reasoning: Bool = false
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
    ]

    public static func spec(id: String) -> LocalModelSpec? {
        models.first { $0.id == id }
    }

    public static func prettyBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
