// Copyright (c) 2026 DOTS
// Piper TTS through sherpa-onnx, loaded at runtime with dlopen. The app binary
// carries no sherpa-onnx or onnxruntime code; the shared libraries are fetched on
// first use (see LocalSpeechRuntime in LocalPiperSpeechSynthesizer.swift).

#ifndef DOTS_PIPER_RUNTIME_H
#define DOTS_PIPER_RUNTIME_H

#include <stdint.h>

typedef struct DotsPiperEngine DotsPiperEngine;

/// Loads `libraryPath` (SherpaOnnxC binary) and creates a VITS engine.
/// Returns NULL when the library or the model cannot be loaded.
DotsPiperEngine *dots_piper_open(const char *libraryPath, const char *modelPath,
                                 const char *tokensPath, const char *dataDir,
                                 int32_t numThreads);

/// Synthesizes `text`. On success returns the sample count, stores a malloc'd
/// buffer in *samples (release with dots_piper_free_samples) and the rate in
/// *sampleRate. Returns 0 on failure.
int32_t dots_piper_generate(DotsPiperEngine *engine, const char *text, int32_t sid,
                            float speed, float **samples, int32_t *sampleRate);

void dots_piper_free_samples(float *samples);
void dots_piper_close(DotsPiperEngine *engine);

#endif
