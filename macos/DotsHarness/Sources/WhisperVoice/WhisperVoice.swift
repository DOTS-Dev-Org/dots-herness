// Copyright (c) 2026 DOTS
// dlopen'd helper: keeps whisper.cpp (and its ggml/Metal payload) out of the
// app's launch-time dyld graph. DotsHarnessCore resolves `dots_whisper_transcribe`
// with dlsym on first use; nothing here is linked by the main executable.

import Foundation
import whisper

/// Reuses the loaded context so every utterance after the first avoids another
/// 574 MB model load. The context lives until the helper dylib is unloaded.
///
/// Returns:
///   0            success, UTF-8 written to `out` (NUL-terminated)
///   > 0          `out` too small; value is the required capacity, retry
///   -1           model failed to load
///   -2           transcription failed
private final class WhisperContextCache: @unchecked Sendable {
    private let lock = NSLock()
    private var modelPath = ""
    private var modelFingerprint: String?
    private var context: OpaquePointer?

    func withContext<T>(_ path: String, _ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }

        let fingerprint = Self.fingerprint(for: path)
        if modelPath != path || modelFingerprint != fingerprint || context == nil {
            if let context { whisper_free(context) }
            var params = whisper_context_default_params()
            params.use_gpu = true
            context = whisper_init_from_file_with_params(path, params)
            modelPath = context == nil ? "" : path
            modelFingerprint = context == nil ? nil : fingerprint
        }
        guard let context else { return nil }
        return body(context)
    }

    private static func fingerprint(for path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value):\(modified.timeIntervalSince1970)"
    }
}

private let whisperContextCache = WhisperContextCache()

@_cdecl("dots_whisper_transcribe")
public func dots_whisper_transcribe(
    _ modelPath: UnsafePointer<CChar>,
    _ samples: UnsafePointer<Float>,
    _ sampleCount: Int32,
    _ threads: Int32,
    _ out: UnsafeMutablePointer<CChar>,
    _ outCapacity: Int32
) -> Int32 {
    let path = String(cString: modelPath)
    guard let result = whisperContextCache.withContext(path, { ctx -> Int32 in
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.detect_language = true
        params.language = nil
        params.temperature = 0

        guard whisper_full(ctx, params, samples, sampleCount) == 0 else { return -2 }

        var text = ""
        for index in 0..<whisper_full_n_segments(ctx) {
            guard let segment = whisper_full_get_segment_text(ctx, index) else { continue }
            let piece = String(cString: segment).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { text += text.isEmpty ? piece : " " + piece }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let bytes = Array(text.utf8)
        guard bytes.count + 1 <= Int(outCapacity) else { return Int32(bytes.count + 1) }
        bytes.withUnsafeBufferPointer { source in
            out.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { destination in
                destination.update(from: source.baseAddress!, count: bytes.count)
            }
        }
        out[bytes.count] = 0
        return 0
    }) else {
        return -1
    }
    return result
}
