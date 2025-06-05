#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <functional> // For std::function

// Forward declarations from whisper.h
struct whisper_context;
struct whisper_full_params;

namespace cactus {

// Callback for partial transcription results during streaming
using STTPartialResultCallback = std::function<void(const std::string& partial_transcript)>;

// Callback for the final transcription result when the stream is finished
using STTFinalResultCallback = std::function<void(const std::string& final_transcript)>;

// Structure for advanced STT control parameters
struct STTAdvancedParams {
    // bool translate = false;          // Translate to English. Default: false (Handled by a separate API method or parameter in whisper_full_params)
    int n_threads = 4;                  // Number of threads. Default: sensible value like 4 or chosen by whisper.cpp based on hardware.

    // Timestamp options
    bool token_timestamps = false;      // Enable token-level timestamps. Default: false
    // bool word_timestamps = false;    // Word timestamps might require post-processing of token_timestamps or specific whisper.cpp flags.
    // bool segment_timestamps = true;  // Segment timestamps are typically default from getTranscription/getSegments.

    // Sampling strategy related
    // Note: whisper.cpp's default strategy is greedy. For beam search, strategy and associated params need to be set.
    // This struct primarily holds parameters that can modify the default strategy's behavior or common settings.
    float temperature = 0.0f;           // Temperature for sampling. Default: 0.0f (deterministic for greedy)
    // int beam_size = 0;               // Beam size for beam search. If > 0, enables beam search. Default: 0 (greedy).
    // float patience = 0.0f;           // Patience for beam search. Default: 0.0f.

    // Performance / Context
    bool speed_up = false;              // Speed up audio processing (2x) via pitch shifting and VAD. Default: false
    int audio_ctx = 0;                  // Audio context size (0 for full context = 1500 for Whisper). Default: 0

    // Segment control
    int max_len = 0;                    // Maximum segment length in characters (0 for no limit). Default: 0
    int max_tokens = 0;                 // Maximum tokens per segment (0 for no limit). Default: 0
    // bool split_on_word = false;      // Split on word boundaries. Default: false.
    // bool single_segment = false;     // Force single segment output. Default: false.

    // Callbacks (Function pointers;
    // these would be set if the user wants to receive these events.
    // For simplicity in this struct, we might omit them and have dedicated setter methods on STT class if needed,
    // or expect users to manage their lifecycle carefully if raw function pointers are used.)
    // whisper_new_segment_callback new_segment_callback = nullptr;
    // whisper_progress_callback progress_callback = nullptr;
    // whisper_encoder_begin_callback encoder_begin_callback = nullptr;

    // Other common parameters from whisper_full_params that might be useful
    bool no_context = true;             // Do not use previous audio context. Default: true (for isolated processAudio calls). Set to false for streaming.
                                        // This is effectively what `keep_context` in whisper-stream CLI does.
    // std::string initial_prompt_override; // If set, overrides STT::user_vocabulary_ for this call. (Handled by setUserVocabulary for persistent prompt)

    // Output control
    // bool print_special = false;
    // bool print_progress = false;      // Already handled by callback if needed
    // bool print_realtime = false;
    // bool print_timestamps = true;     // Timestamps are part of segment data usually.

    // Constructor with default values
    STTAdvancedParams() = default;
};


class STT {
public:
    STT();
    ~STT();

    // Initialize the STT engine with a model path
    // model_path: Path to the ggml Whisper model file.
    // language: Language code (e.g., "en").
    // use_gpu: Whether to attempt GPU usage (if compiled with GPU support).
    bool initialize(const std::string& model_path, const std::string& language = "en", bool use_gpu = true);

    // Process audio samples for transcription.
    // samples: A vector of float audio samples (PCM 32-bit, 16kHz, mono).
    // For simplicity in this initial version, we assume the input audio is already in the correct format.
    bool processAudio(const std::vector<float>& samples); // Uses default parameters
    bool processAudioWithParams(const std::vector<float>& samples, const STTAdvancedParams& params);

    // Get the full transcribed text.
    std::string getTranscription();

    // (Optional Advanced) Get individual text segments with timestamps.
    // struct Segment { std::string text; int64_t t0; int64_t t1; };
    // std::vector<Segment> getSegments();

    /**
     * @brief Sets a user-specific vocabulary (initial prompt) for STT processing.
     *
     * The provided string will be used as the `initial_prompt` in `whisper_full_params`
     * to guide the transcription process.
     *
     * @param vocabulary The vocabulary/prompt string. An empty string will clear any
     *                   previously set vocabulary.
     */
    void setUserVocabulary(const std::string& vocabulary);

    bool isInitialized() const;

    /**
     * @brief Gets the currently set user vocabulary. (For testing purposes)
     * @return A const reference to the internal user vocabulary string.
     */
    const std::string& getUserVocabularyForTest() const { return user_vocabulary_; }

    // --- Streaming API ---

    // Starts a new streaming session.
    // Resets any existing stream state.
    // params: Advanced parameters for this streaming session.
    // partial_cb: Callback invoked with partial transcription results.
    // final_cb: Callback invoked with the final transcription when finishStream() is called.
    // Returns true on success, false on failure (e.g., if STT not initialized).
    bool startStream(const STTAdvancedParams& params,
                     STTPartialResultCallback partial_cb,
                     STTFinalResultCallback final_cb);

    // Processes a chunk of audio data during an active streaming session.
    // Audio samples should be PCM 32-bit float, 16kHz, mono.
    // Returns true if chunk was accepted, false if not streaming or error.
    bool processAudioChunk(const std::vector<float>& audio_chunk);

    // Signals the end of the audio stream.
    // Processes any remaining audio in the internal buffer.
    // Invokes the FinalResultCallback with the complete transcription.
    // Returns true on success, false on error or if not streaming.
    bool finishStream();

private:
    void cleanup();

    whisper_context* ctx_ = nullptr;
    std::string language_ = "en";
    std::string user_vocabulary_;
    // Potentially add members for whisper_full_params if customization is needed beyond defaults.
    // Or, create whisper_full_params on the stack in processAudio.

    // --- Streaming State Members ---
    std::vector<float> stream_audio_buffer_;      // Internal buffer for accumulating audio chunks
    STTPartialResultCallback stt_partial_result_cb_; // User callback for partial results
    STTFinalResultCallback stt_final_result_cb_;     // User callback for final result
    STTAdvancedParams current_stream_params_;         // Parameters for the current stream
    bool is_streaming_active_ = false;                // Flag indicating if a stream is active
    std::string accumulated_stream_transcription_;    // Accumulates transcription during streaming
};

} // namespace cactus
