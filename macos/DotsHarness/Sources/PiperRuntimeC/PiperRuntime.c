// Copyright (c) 2026 DOTS
// sherpa-onnx's C API is resolved with dlsym, so nothing here links against it.
// The config mirrors sherpa's Swift helpers (NULL strings become "", zero floats
// fall back to sherpa defaults), so synthesis matches the previous static build.

#include "PiperRuntime.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#include "vendor/sherpa-onnx/c-api/c-api.h"

typedef __typeof__(SherpaOnnxCreateOfflineTts) *CreateFn;
typedef __typeof__(SherpaOnnxDestroyOfflineTts) *DestroyFn;
typedef __typeof__(SherpaOnnxOfflineTtsGenerateWithConfig) *GenerateFn;
typedef __typeof__(SherpaOnnxDestroyOfflineTtsGeneratedAudio) *FreeAudioFn;

struct DotsPiperEngine {
  const SherpaOnnxOfflineTts *tts;
  DestroyFn destroy;
  GenerateFn generate;
  FreeAudioFn freeAudio;
};

DotsPiperEngine *dots_piper_open(const char *libraryPath, const char *modelPath,
                                 const char *tokensPath, const char *dataDir,
                                 int32_t numThreads) {
  // Never dlclose: onnxruntime keeps process-wide thread pools.
  void *library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL);
  if (!library) return NULL;

  CreateFn create = (CreateFn)dlsym(library, "SherpaOnnxCreateOfflineTts");
  DestroyFn destroy = (DestroyFn)dlsym(library, "SherpaOnnxDestroyOfflineTts");
  GenerateFn generate = (GenerateFn)dlsym(library, "SherpaOnnxOfflineTtsGenerateWithConfig");
  FreeAudioFn freeAudio = (FreeAudioFn)dlsym(library, "SherpaOnnxDestroyOfflineTtsGeneratedAudio");
  if (!create || !destroy || !generate || !freeAudio) return NULL;

  SherpaOnnxOfflineTtsConfig config;
  memset(&config, 0, sizeof(config));
  config.model.vits.model = modelPath;
  config.model.vits.tokens = tokensPath;
  config.model.vits.data_dir = dataDir;
  config.model.vits.noise_scale = 0.667f;
  config.model.vits.noise_scale_w = 0.8f;
  config.model.vits.length_scale = 1.0f;
  config.model.num_threads = numThreads;
  config.model.provider = "cpu";
  config.max_num_sentences = 1;
  config.silence_scale = 0.2f;

  const SherpaOnnxOfflineTts *tts = create(&config);
  if (!tts) return NULL;

  DotsPiperEngine *engine = calloc(1, sizeof(DotsPiperEngine));
  if (!engine) {
    destroy(tts);
    return NULL;
  }
  engine->tts = tts;
  engine->destroy = destroy;
  engine->generate = generate;
  engine->freeAudio = freeAudio;
  return engine;
}

int32_t dots_piper_generate(DotsPiperEngine *engine, const char *text, int32_t sid,
                            float speed, float **samples, int32_t *sampleRate) {
  *samples = NULL;
  *sampleRate = 0;

  SherpaOnnxGenerationConfig generation;
  memset(&generation, 0, sizeof(generation));
  generation.silence_scale = 0.2f;
  generation.speed = speed;
  generation.sid = sid;
  generation.reference_sample_rate = 16000;
  generation.reference_text = "";
  generation.num_steps = 1;
  generation.extra = "{}";

  const SherpaOnnxGeneratedAudio *audio =
      engine->generate(engine->tts, text, &generation, NULL, NULL);
  if (!audio) return 0;

  int32_t count = audio->n;
  if (count <= 0 || !audio->samples) {
    engine->freeAudio(audio);
    return 0;
  }

  float *copy = malloc(sizeof(float) * (size_t)count);
  if (copy) {
    memcpy(copy, audio->samples, sizeof(float) * (size_t)count);
    *samples = copy;
    *sampleRate = audio->sample_rate;
  } else {
    count = 0;
  }
  engine->freeAudio(audio);
  return count;
}

void dots_piper_free_samples(float *samples) { free(samples); }

void dots_piper_close(DotsPiperEngine *engine) {
  if (!engine) return;
  engine->destroy(engine->tts);
  free(engine);
}
