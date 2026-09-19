#pragma once

#include <stdint.h>

#if defined(_WIN32)
#  if defined(DOTS_VISION_BUILD)
#    define DOTS_VISION_API __declspec(dllexport)
#  else
#    define DOTS_VISION_API __declspec(dllimport)
#  endif
#else
#  define DOTS_VISION_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

DOTS_VISION_API void * dots_vision_create(
    const char * text_model_path,
    const char * projector_path,
    int32_t threads);

DOTS_VISION_API int32_t dots_vision_describe(
    void * context,
    const char * image_path,
    const char * instruction,
    char ** output);

DOTS_VISION_API void dots_vision_free_string(char * value);
DOTS_VISION_API void dots_vision_destroy(void * context);
DOTS_VISION_API const char * dots_vision_last_error(void);

#ifdef __cplusplus
}
#endif
