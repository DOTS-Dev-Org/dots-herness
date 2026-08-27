// Copyright (c) 2026 DOTS
// dlopen'd helper: keeps whisper.cpp (and its ggml/Metal payload) out of the
// app's launch-time dyld graph. DotsHarnessCore resolves `dots_whisper_transcribe`
// with dlsym on first use; nothing here is linked by the main executable.

import Foundation
import whisper

/// One-shot transcription. Loads the model, runs whisper, frees everything —
/// no context is retained between calls, so idle voice keeps zero whisper memory.
///
/// Returns:
///   0            success, UTF-8 written to `out` (NUL-terminated)
///   > 0          `out` too small; value is the required capacity, retry
///   -1           model failed to load
///   -2           transcription failed
@_cdecl("dots_whisper_transcribe")
public func dots_whisper_transcribe(
    _ modelPath: UnsafePointer<CChar>,
    _ samples: UnsafePointer<Float>,
    _ sampleCount: Int32,
    _ threads: Int32,
    _ out: UnsafeMutablePointer<CChar>,
    _ outCapacity: Int32
) -> Int32 {
    var contextParams = whisper_context_default_params()
    contextParams.use_gpu = true
    guard let ctx = whisper_init_from_file_with_params(String(cString: modelPath), contextParams) else {
        return -1
    }
    defer { whisper_free(ctx) }

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
}
