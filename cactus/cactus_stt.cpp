#include "cactus_stt.h"
#include "whisper.h" // Assuming whisper.h is in the include path
#include <functional> // For std::function (already in cactus_stt.h but good practice for .cpp)
#include <cstdio> // For fprintf, stderr
#include <vector>
#include <string> // For std::string (already in cactus_stt.h but good practice for .cpp)


// Test hook for capturing initial_prompt
// This should ideally be guarded by a compile-time flag (e.g., #ifdef ENABLE_TEST_HOOKS)
// For simplicity here, it's always included. Ensure it's not used in production builds
// if this approach is maintained.
const char* g_last_initial_prompt_for_test = nullptr;


namespace cactus {

// Static callback function to be used with whisper_full_params
static void whisper_new_segment_callback_static(struct whisper_context *ctx_whisper, struct whisper_state * /*state*/, int n_new, void *user_data) {
    STT* stt_instance = static_cast<STT*>(user_data);
    if (!stt_instance || !stt_instance->is_streaming_active_) { // Check if still streaming
        return;
    }

    // Note: Accessing stt_instance->ctx_ directly here is okay if this callback is only ever
    // used in scenarios where ctx_ is the same as ctx_whisper.
    // For robustness, one might pass stt_instance->ctx_ to whisper_full_n_segments and whisper_full_get_segment_text
    // if there's any doubt, but typically they are the same context during a single STT operation.
    const int n_segments = whisper_full_n_segments(ctx_whisper);
    for (int i = n_segments - n_new; i < n_segments; ++i) { // Iterate over newly added segments
        const char* segment_text = whisper_full_get_segment_text(ctx_whisper, i);
        if (segment_text) {
            std::string segment_str = segment_text;
            stt_instance->accumulated_stream_transcription_ += segment_str;
            // Optional: Add a separator if segments don't naturally include trailing spaces.
            // stt_instance->accumulated_stream_transcription_ += " ";

            if (stt_instance->stt_partial_result_cb_) {
                stt_instance->stt_partial_result_cb_(segment_str); // Pass new segment text as partial result
            }
        }
    }
}


STT::STT() : ctx_(nullptr), language_("en"), user_vocabulary_(""), is_streaming_active_(false) {
    // Constructor: Initialize members, including is_streaming_active_
}

STT::~STT() {
    cleanup();
}

bool STT::initialize(const std::string& model_path, const std::string& language, bool use_gpu) {
    if (ctx_) {
        fprintf(stderr, "STT: Already initialized. Call cleanup() first.\n");
        return false;
    }

    language_ = language;

    // Whisper context parameters
    whisper_context_params cparams = whisper_context_params_default();
    cparams.use_gpu = use_gpu;

    ctx_ = whisper_init_from_file_with_params(model_path.c_str(), cparams);

    if (ctx_ == nullptr) {
        fprintf(stderr, "STT: Failed to initialize whisper context from model '%s'\n", model_path.c_str());
        return false;
    }

    return true;
}

bool STT::processAudio(const std::vector<float>& samples) {
    STTAdvancedParams default_params;
    return processAudioWithParams(samples, default_params);
}

bool STT::processAudioWithParams(const std::vector<float>& samples, const STTAdvancedParams& params) {
    if (!ctx_) {
        fprintf(stderr, "STT: Not initialized. Call initialize() first.\n");
        return false;
    }

    if (samples.empty()) {
        fprintf(stderr, "STT: Audio samples vector is empty.\n");
        return false;
    }

    // For simplicity, we use default whisper_full_params.
    // These can be customized further if needed.
    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    // Set language if it was provided and is different from default.
    // whisper.h typically defaults to "en" if params.language is nullptr.
    // However, explicitly setting it ensures the desired language is used.
    wparams.language = language_.c_str(); // Language set during STT::initialize

    // Apply user vocabulary (persistent initial prompt) if set
    if (!user_vocabulary_.empty()) {
        wparams.initial_prompt = user_vocabulary_.c_str();
    } else {
        wparams.initial_prompt = nullptr;
    }

    // Apply advanced parameters from the params struct
    wparams.n_threads = params.n_threads;
    wparams.token_timestamps = params.token_timestamps; // part of whisper_full_params directly in whisper.h

    // Temperature is part of the sampling strategy substruct
    // Assuming greedy strategy for now as whisper_full_default_params(WHISPER_SAMPLING_GREEDY) is used.
    // If other strategies were selectable via STTAdvancedParams, this would need to change.
    wparams.sampling.temperature = params.temperature;

    wparams.speed_up = params.speed_up;
    wparams.audio_ctx = params.audio_ctx;

    if (params.max_len > 0) { // whisper.h uses 0 for disabled
        wparams.max_len = params.max_len;
    }
    if (params.max_tokens > 0) { // whisper.h uses 0 for disabled
         wparams.max_tokens = params.max_tokens;
    }

    wparams.no_context = params.no_context;
    // Note: We are not overriding initial_prompt from STTAdvancedParams here,
    // as user_vocabulary_ serves as the persistent initial prompt.
    // If an override was desired, logic would be:
    // if (!params.initial_prompt_override.empty()) {
    //    wparams.initial_prompt = params.initial_prompt_override.c_str();
    // }

    // Test Hook: Capture the final initial_prompt that will be used.
    g_last_initial_prompt_for_test = wparams.initial_prompt;

    // Callbacks would be set here if they were part of STTAdvancedParams and non-null
    // wparams.new_segment_callback = params.new_segment_callback;
    // wparams.progress_callback = params.progress_callback;
    // wparams.encoder_begin_callback = params.encoder_begin_callback;

    // Disable printing progress to stderr from whisper.cpp by default, can be overridden by params if exposed
    // wparams.print_progress = params.print_progress;
    // wparams.print_special = params.print_special;
    // wparams.print_realtime = params.print_realtime;
    // wparams.print_timestamps = params.print_timestamps;


    if (whisper_full(ctx_, wparams, samples.data(), samples.size()) != 0) {
        fprintf(stderr, "STT: Failed to process audio with custom params\n");
        return false;
    }

    return true;
}

std::string STT::getTranscription() {
    if (!ctx_) {
        fprintf(stderr, "STT: Not initialized. Cannot get transcription.\n");
        return "";
    }

    std::string full_text;
    const int n_segments = whisper_full_n_segments(ctx_);
    for (int i = 0; i < n_segments; ++i) {
        const char* segment_text = whisper_full_get_segment_text(ctx_, i);
        if (segment_text) {
            full_text += segment_text;
        }
    }
    return full_text;
}

void STT::setUserVocabulary(const std::string& vocabulary) {
    user_vocabulary_ = vocabulary;
}

// (Optional Advanced) Get individual text segments with timestamps.
// std::vector<STT::Segment> STT::getSegments() {
//     std::vector<Segment> segments;
//     if (!ctx_) {
//         fprintf(stderr, "STT: Not initialized. Cannot get segments.\n");
//         return segments;
//     }
//     const int n_segments = whisper_full_n_segments(ctx_);
//     for (int i = 0; i < n_segments; ++i) {
//         const char* text = whisper_full_get_segment_text(ctx_, i);
//         int64_t t0 = whisper_full_get_segment_t0(ctx_, i);
//         int64_t t1 = whisper_full_get_segment_t1(ctx_, i);
//         if (text) {
//             segments.push_back({text, t0, t1});
//         }
//     }
//     return segments;
// }

bool STT::isInitialized() const {
    return ctx_ != nullptr;
}

void STT::cleanup() {
    if (ctx_) {
        whisper_free(ctx_);
        ctx_ = nullptr;
    }
    // Clean up streaming state as well
    stream_audio_buffer_.clear();
    accumulated_stream_transcription_.clear();
    stt_partial_result_cb_ = nullptr;
    stt_final_result_cb_ = nullptr;
    is_streaming_active_ = false;
}

// --- Streaming API Implementations ---

bool STT::startStream(const STTAdvancedParams& params,
                      STTPartialResultCallback partial_cb,
                      STTFinalResultCallback final_cb) {
    if (!ctx_) {
        fprintf(stderr, "STT: Cannot start stream, context not initialized.\n");
        return false;
    }
    if (is_streaming_active_) {
        fprintf(stderr, "STT: Stream already active. Call finishStream() before starting a new one.\n");
        // Or, implicitly call finishStream() here. For now, require explicit finish.
        return false;
    }

    current_stream_params_ = params;
    stt_partial_result_cb_ = partial_cb;
    stt_final_result_cb_ = final_cb;

    stream_audio_buffer_.clear();
    accumulated_stream_transcription_.clear();
    is_streaming_active_ = true;

    // Reset whisper context state related to previous full transcriptions if any.
    // whisper_reset_context_state(ctx_); // This function may or may not exist or be needed.
    // For now, we assume new whisper_full calls correctly handle continuous state
    // when `no_context` is false in params, or reset state if `no_context` is true.
    // The `stream` example in whisper.cpp itself re-uses the context without explicit reset,
    // relying on the sliding window of audio and `no_context`/`keep_context` behavior.

    // The first call to processAudioChunk will use current_stream_params_.no_context
    // to determine if context from a *previous non-streaming* call to processAudio should be kept.
    // Typically for a new stream, you'd want no_context = true for the very first segment of the stream.
    // This is handled by current_stream_params_.no_context.

    return true;
}

bool STT::processAudioChunk(const std::vector<float>& audio_chunk) {
    if (!is_streaming_active_ || !ctx_) {
        fprintf(stderr, "STT: Cannot process audio chunk, stream not active or context not initialized.\n");
        return false;
    }
    if (audio_chunk.empty()) {
        return true; // No data to process, but not an error.
    }

    stream_audio_buffer_.insert(stream_audio_buffer_.end(), audio_chunk.begin(), audio_chunk.end());

    // Simplified processing strategy: process the whole buffer for now.
    // A more advanced strategy would involve fixed-size chunks or VAD.
    // This matches the behavior if min_buffer_processing_size_samples is small or not used.
    // The key is that whisper_full can be called multiple times, and it processes what's given.

    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY); // Or strategy from current_stream_params_

    // Apply parameters from current_stream_params_
    wparams.language = language_.c_str(); // From STT instance
    wparams.n_threads = current_stream_params_.n_threads;
    wparams.token_timestamps = current_stream_params_.token_timestamps;
    wparams.sampling.temperature = current_stream_params_.temperature;
    wparams.speed_up = current_stream_params_.speed_up;
    wparams.audio_ctx = current_stream_params_.audio_ctx;
    if (current_stream_params_.max_len > 0) wparams.max_len = current_stream_params_.max_len;
    if (current_stream_params_.max_tokens > 0) wparams.max_tokens = current_stream_params_.max_tokens;

    // For streaming:
    // `no_context` should be false to use context from previous chunks *within the same stream*.
    // The `current_stream_params_.no_context` is for the *start* of the stream relative to prior non-streaming calls.
    // For subsequent chunks in a stream, context should be kept.
    // whisper.cpp's `stream` example manages this by keeping some audio from previous chunk (`keep_ms`)
    // and setting `no_context` in whisper_full_params based on whether it's the first chunk of a detected speech segment by VAD.
    // For this simplified API, if `current_stream_params_.no_context` was true for startStream,
    // it implies the first chunk is processed without prior context. Subsequent chunks should use context.
    // We can achieve this by setting wparams.no_context = false for calls *within* a stream after the first effective processing.
    // However, whisper_full itself manages context based on tokens in whisper_state.
    // If accumulated_stream_transcription_ is not empty, it means we have prior context *from this stream*.
    wparams.no_context = accumulated_stream_transcription_.empty() ? current_stream_params_.no_context : false;


    if (!user_vocabulary_.empty()) {
        wparams.initial_prompt = user_vocabulary_.c_str();
    } else {
        wparams.initial_prompt = nullptr;
    }

    // Set callbacks
    wparams.new_segment_callback = whisper_new_segment_callback_static;
    wparams.new_segment_callback_user_data = this;

    // Test hook (might be less relevant for streaming chunks vs full process)
    g_last_initial_prompt_for_test = wparams.initial_prompt;

    // Process the current accumulated buffer
    if (whisper_full(ctx_, wparams, stream_audio_buffer_.data(), stream_audio_buffer_.size()) != 0) {
        fprintf(stderr, "STT: whisper_full failed during stream processing.\n");
        is_streaming_active_ = false; // Stop stream on error
        if(stt_final_result_cb_) stt_final_result_cb_(""); // Indicate error with empty result
        return false;
    }

    // Clear buffer after processing. A more advanced implementation would handle overlaps.
    stream_audio_buffer_.clear();

    return true;
}

bool STT::finishStream() {
    if (!is_streaming_active_ || !ctx_) {
        fprintf(stderr, "STT: Cannot finish stream, not active or context not initialized.\n");
        return false;
    }

    // Process any remaining audio in the buffer
    if (!stream_audio_buffer_.empty()) {
        // Use a copy of current_stream_params, but ensure no_context is false for the final part
        // to connect with previous parts of the stream.
        // The prompt should also ideally not be re-applied if it was for the beginning.
        whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        wparams.language = language_.c_str();
        wparams.n_threads = current_stream_params_.n_threads;
        wparams.token_timestamps = current_stream_params_.token_timestamps;
        wparams.sampling.temperature = current_stream_params_.temperature;
        wparams.speed_up = current_stream_params_.speed_up;
        wparams.audio_ctx = current_stream_params_.audio_ctx;
        if (current_stream_params_.max_len > 0) wparams.max_len = current_stream_params_.max_len;
        if (current_stream_params_.max_tokens > 0) wparams.max_tokens = current_stream_params_.max_tokens;

        wparams.no_context = accumulated_stream_transcription_.empty() ? current_stream_params_.no_context : false;

        // For the final chunk, we might not need the initial_prompt if it was already processed
        // and context is being carried. However, if user_vocabulary is meant as a persistent guide,
        // it should be included.
        if (!user_vocabulary_.empty()) {
            wparams.initial_prompt = user_vocabulary_.c_str();
        } else {
            wparams.initial_prompt = nullptr;
        }

        wparams.new_segment_callback = whisper_new_segment_callback_static;
        wparams.new_segment_callback_user_data = this;
        g_last_initial_prompt_for_test = wparams.initial_prompt;


        if (whisper_full(ctx_, wparams, stream_audio_buffer_.data(), stream_audio_buffer_.size()) != 0) {
            fprintf(stderr, "STT: whisper_full failed during final stream processing.\n");
            // Still attempt to call final callback with what we have
        }
        stream_audio_buffer_.clear();
    }

    if (stt_final_result_cb_) {
        stt_final_result_cb_(accumulated_stream_transcription_);
    }

    is_streaming_active_ = false;
    stt_partial_result_cb_ = nullptr;
    stt_final_result_cb_ = nullptr;
    accumulated_stream_transcription_.clear();
    // current_stream_params_ is POD so no special clear needed.

    return true;
}


} // namespace cactus
