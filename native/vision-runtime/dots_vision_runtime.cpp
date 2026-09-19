#include "dots_vision_runtime.h"

#include "llama.h"
#include "mtmd-helper.h"
#include "mtmd.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

thread_local std::string last_error;
std::mutex backend_mutex;
int backend_users = 0;

void set_error(std::string message) {
    last_error = std::move(message);
}

void acquire_backend() {
    std::lock_guard lock(backend_mutex);
    if (backend_users++ == 0) llama_backend_init();
}

void release_backend() {
    std::lock_guard lock(backend_mutex);
    if (--backend_users == 0) llama_backend_free();
}

std::string apply_chat_template(llama_model * model, const std::string & instruction) {
    const char * template_name = llama_model_chat_template(model, nullptr);
    if (!template_name) throw std::runtime_error("SmolVLM has no chat template");
    const std::string content = std::string(mtmd_default_marker()) + "\n" + instruction;
    llama_chat_message message { "user", content.c_str() };

    size_t capacity = 2048;
    for (int attempt = 0; attempt < 3; ++attempt) {
        std::vector<char> buffer(capacity, '\0');
        const int32_t length = llama_chat_apply_template(
            template_name,
            &message,
            1,
            true,
            buffer.data(),
            static_cast<int32_t>(buffer.size()));
        if (length < 0) throw std::runtime_error("SmolVLM chat template failed");
        if (static_cast<size_t>(length) < buffer.size()) return std::string(buffer.data(), length);
        capacity = static_cast<size_t>(length) + 1;
    }
    throw std::runtime_error("SmolVLM chat template is too large");
}

std::string token_piece(const llama_vocab * vocab, llama_token token) {
    std::vector<char> buffer(128, '\0');
    for (int attempt = 0; attempt < 3; ++attempt) {
        const int32_t length = llama_token_to_piece(
            vocab,
            token,
            buffer.data(),
            static_cast<int32_t>(buffer.size()),
            0,
            false);
        if (length >= 0 && static_cast<size_t>(length) <= buffer.size()) {
            return std::string(buffer.data(), length);
        }
        if (length < 0) buffer.resize(static_cast<size_t>(-length) + 1);
    }
    return {};
}

struct VisionContext {
    llama_model * model = nullptr;
    llama_context * language = nullptr;
    mtmd_context * vision = nullptr;
    const llama_vocab * vocab = nullptr;
    int32_t batch = 512;
    std::mutex inference_mutex;

    ~VisionContext() {
        if (vision) mtmd_free(vision);
        if (language) llama_free(language);
        if (model) llama_model_free(model);
        release_backend();
    }
};

} // namespace

extern "C" {

void * dots_vision_create(const char * text_model_path, const char * projector_path, int32_t threads) {
    std::unique_ptr<VisionContext> context;
    bool backend_acquired = false;
    try {
        if (!text_model_path || !projector_path) throw std::runtime_error("Vision model paths are missing");
        acquire_backend();
        backend_acquired = true;

        context = std::make_unique<VisionContext>();
        auto model_params = llama_model_default_params();
        model_params.n_gpu_layers = 0; // portable CPU fallback; no GPU dependency in the plugin.
        context->model = llama_model_load_from_file(text_model_path, model_params);
        if (!context->model) throw std::runtime_error("Could not load SmolVLM text model");

        auto context_params = llama_context_default_params();
        context_params.n_ctx = 2048;
        context_params.n_batch = context->batch;
        context_params.n_ubatch = context->batch;
        context_params.n_seq_max = 1;
        context_params.n_threads = std::max<int32_t>(1, threads);
        context_params.n_threads_batch = std::max<int32_t>(1, threads);
        context->language = llama_init_from_model(context->model, context_params);
        if (!context->language) throw std::runtime_error("Could not create SmolVLM context");

        auto vision_params = mtmd_context_params_default();
        vision_params.use_gpu = false;
        vision_params.n_threads = std::max<int32_t>(1, threads);
        vision_params.batch_max_tokens = context->batch;
        context->vision = mtmd_init_from_file(projector_path, context->model, vision_params);
        if (!context->vision || !mtmd_support_vision(context->vision)) {
            throw std::runtime_error("Could not initialize SmolVLM projector");
        }
        context->vocab = llama_model_get_vocab(context->model);
        return context.release();
    } catch (const std::exception & error) {
        if (!context && backend_acquired) release_backend();
        set_error(error.what());
        return nullptr;
    } catch (...) {
        if (!context && backend_acquired) release_backend();
        set_error("Unknown Vision runtime initialization error");
        return nullptr;
    }
}

int32_t dots_vision_describe(void * raw, const char * image_path, const char * instruction, char ** output) {
    if (!raw || !image_path || !instruction || !output) {
        set_error("Vision runtime received an invalid input");
        return 1;
    }
    *output = nullptr;
    auto * context = static_cast<VisionContext *>(raw);
    std::lock_guard lock(context->inference_mutex);
    try {
        llama_memory_clear(llama_get_memory(context->language), true);
        const auto prompt = apply_chat_template(context->model, instruction);
        const auto bitmap_result = mtmd_helper_bitmap_init_from_file(
            context->vision,
            image_path,
            false,
            mtmd_helper_init_opt_default());
        if (!bitmap_result.bitmap) throw std::runtime_error("Could not decode image");

        mtmd_input_chunks * chunks = mtmd_input_chunks_init();
        if (!chunks) {
            mtmd_bitmap_free(bitmap_result.bitmap);
            if (bitmap_result.video_ctx) mtmd_helper_video_free(bitmap_result.video_ctx);
            throw std::runtime_error("Could not allocate image prompt chunks");
        }
        bool media_released = false;
        auto release_media = [&]() {
            if (media_released) return;
            mtmd_bitmap_free(bitmap_result.bitmap);
            if (bitmap_result.video_ctx) mtmd_helper_video_free(bitmap_result.video_ctx);
            media_released = true;
        };
        const mtmd_bitmap * bitmaps[] = { bitmap_result.bitmap };
        mtmd_input_text text {
            prompt.c_str(),
            prompt.size(),
            true,
            true,
        };
        try {
            const int32_t tokenize_result = mtmd_tokenize(
                context->vision,
                chunks,
                &text,
                bitmaps,
                1);
            release_media();
            if (tokenize_result != 0) {
                mtmd_input_chunks_free(chunks);
                chunks = nullptr;
                throw std::runtime_error("Could not preprocess image");
            }

            llama_pos n_past = 0;
            const int32_t eval_result = mtmd_helper_eval_chunks(
                context->vision,
                context->language,
                chunks,
                0,
                0,
                context->batch,
                true,
                &n_past);
            mtmd_input_chunks_free(chunks);
            chunks = nullptr;
            if (eval_result != 0) throw std::runtime_error("Could not evaluate image prompt");
        } catch (...) {
            // The normal path frees the bitmap and chunks before sampling.
            // Keep this guard for allocation/decoder failures from the mtmd API.
            release_media();
            if (chunks) mtmd_input_chunks_free(chunks);
            throw;
        }

        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
            llama_sampler_init_greedy(), llama_sampler_free);
        if (!sampler) throw std::runtime_error("Could not initialize Vision sampler");
        std::string answer;
        for (int token_index = 0; token_index < 256; ++token_index) {
            const auto token = llama_sampler_sample(sampler.get(), context->language, -1);
            if (llama_vocab_is_eog(context->vocab, token)) break;
            llama_sampler_accept(sampler.get(), token);
            answer += token_piece(context->vocab, token);
            auto batch = llama_batch_get_one(const_cast<llama_token *>(&token), 1);
            if (llama_decode(context->language, batch) != 0) {
                throw std::runtime_error("Could not decode Vision response");
            }
        }
        *output = static_cast<char *>(std::malloc(answer.size() + 1));
        if (!*output) throw std::bad_alloc();
        std::memcpy(*output, answer.c_str(), answer.size() + 1);
        return 0;
    } catch (const std::exception & error) {
        set_error(error.what());
        return 1;
    } catch (...) {
        set_error("Unknown Vision runtime inference error");
        return 1;
    }
}

void dots_vision_free_string(char * value) {
    std::free(value);
}

void dots_vision_destroy(void * raw) {
    delete static_cast<VisionContext *>(raw);
}

const char * dots_vision_last_error(void) {
    return last_error.c_str();
}

} // extern "C"
