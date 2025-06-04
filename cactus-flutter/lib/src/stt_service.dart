import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:io' show Platform; // For platform-specific library names

import 'dart:async'; // For StreamController and Completer
// Assuming the generated bindings will be in this path, based on ffigen.yaml
import '../cactus_bindings_generated.dart';
import '../src/stt_options.dart'; // Import SttOptions
// Ensure ffi.dart is imported for Pointer, malloc, free, etc.
// import 'package:ffi/ffi.dart'; // Already imported via other means if not explicitly. For clarity:
import 'package:ffi/ffi.dart' show malloc, Utf8;


// Helper class for StableCell payload to pass multiple Dart objects via a single user_data pointer
class _SttStreamCallbackPayload {
  final StreamController<String> partialController;
  final Completer<String> finalCompleter;
  // Optional: Add a direct error callback if native side can report errors via a separate C callback
  // final Function(Object error)? onError;

  _SttStreamCallbackPayload(this.partialController, this.finalCompleter /*, this.onError*/);
}

// Static callback dispatchers - these are the entry points from C code.
// They use user_data (which will be a StableCell reference) to get back to the Dart objects.
void _staticPartialCallbackDispatcher(Pointer<Utf8> transcript, Pointer<Void> userData) {
    if (userData == nullptr) return;
    final stableCellRef = userData.cast<StableCellReference<_SttStreamCallbackPayload>>();
    final payload = stableCellRef.value;
    if (payload != null) {
        final controller = payload.partialController;
        if (!controller.isClosed) {
            controller.add(transcript.toDartString());
        }
    }
}

void _staticFinalCallbackDispatcher(Pointer<Utf8> transcript, Pointer<Void> userData) {
    if (userData == nullptr) return;
    final stableCellRef = userData.cast<StableCellReference<_SttStreamCallbackPayload>>();
    final payload = stableCellRef.value;
    if (payload != null) {
        final completer = payload.finalCompleter;
        final partialController = payload.partialController;

        if (!completer.isCompleted) {
            completer.complete(transcript.toDartString());
        }
        // It's good practice to close the partials controller when the final result is in.
        if (!partialController.isClosed) {
            partialController.close();
        }
        // The StableCell should be disposed of after the final callback has been processed.
        // This is handled in startStreamingSTT's completer.future.whenComplete.
    }
}


/// Manages Speech-to-Text (STT) operations using the Cactus native library.
class CactusSTTService {
  /// Holds the native bindings, loaded from the dynamic library.
  late final CactusBindings _bindings;

  /// Pointer to the native STT context. Null if not initialized.
  Pointer<cactus_stt_context_t> _sttContext = nullptr;

  /// Flag to indicate if the service is initialized and context is valid.
  bool get isInitialized => _sttContext != nullptr;

  // For managing callbacks from native code
  Pointer<NativeFunction<stt_partial_result_callback_c_t>>? _nativePartialCallbackPtr;
  Pointer<NativeFunction<stt_final_result_callback_c_t>>? _nativeFinalCallbackPtr;
  StableCell? _streamCallbackStableCell; // To hold the _SttStreamCallbackPayload

  // User-provided Dart callbacks (stored if needed, but primarily managed via Completer/StreamController now)
  // Function(String partialTranscript)? _onPartialResult; // Handled by StreamController
  // Function(String finalTranscript)? _onFinalResult;    // Handled by Completer
  Function(Object error)? _onStreamError;

  // To bridge async results from native callbacks to Dart futures/streams
  StreamController<String>? _partialTranscriptStreamController;
  Completer<String>? _finalTranscriptCompleter;

  bool _isStreaming = false;
  /// Indicates if a streaming session is currently active.
  bool get isStreaming => _isStreaming;


  /// Loads the native library and initializes the bindings.
  ///
  /// Throws an [Exception] if the library cannot be loaded.
  CactusSTTService() {
    _bindings = CactusBindings(_loadLibrary());
  }

  DynamicLibrary _loadLibrary() {
    if (Platform.isMacOS || Platform.isIOS) {
      // On iOS/macOS, use DynamicLibrary.process() to find symbols in the main executable,
      // assuming the static library is linked. For a dynamic framework, use DynamicLibrary.open().
      // For simplicity with Flutter, where native code is often bundled, process() is a common start.
      // If it's a separate .dylib or .framework, 'path/to/libcactus_core.dylib' would be used.
      return DynamicLibrary.process();
    } else if (Platform.isAndroid) {
      return DynamicLibrary.open('libcactus_core.so');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libcactus_core.so');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('cactus_core.dll');
    }
    throw Exception('Unsupported platform for loading native library.');
  }

  /// Initializes the STT engine with the specified model.
  ///
  /// [modelPath]: Path to the ggml Whisper model file.
  /// [language]: Language code (e.g., "en").
  /// Returns `true` if initialization is successful, `false` otherwise.
  Future<bool> initialize(String modelPath, String language) async {
    if (isInitialized) {
      print('STT Service already initialized. Please free the existing instance first.');
      return true; // Or false, depending on desired behavior for re-initialization
    }

    Pointer<Utf8> modelPathPtr = modelPath.toNativeUtf8();
    Pointer<Utf8> languagePtr = language.toNativeUtf8();

    try {
      _sttContext = _bindings.cactus_stt_init(modelPathPtr, languagePtr);
      if (_sttContext == nullptr) {
        print('Failed to initialize STT context: cactus_stt_init returned nullptr.');
        return false;
      }
      return true;
    } catch (e) {
      print('Exception during STT initialization: $e');
      _sttContext = nullptr; // Ensure context is null on error
      return false;
    } finally {
      malloc.free(modelPathPtr);
      malloc.free(languagePtr);
    }
  }

  /// Sets a user-specific vocabulary (initial prompt) to guide the STT engine.
  ///
  /// This can improve transcription accuracy for specific terms or contexts.
  /// Throws an [Exception] if the STT service is not initialized or
  /// if setting the vocabulary fails at the native level (e.g., string conversion error).
  ///
  /// - Parameter vocabulary: A [String] containing words or phrases.
  void setUserVocabulary(String vocabulary) {
    if (!isInitialized) {
      print("CactusSTTService: Cannot set user vocabulary, STT not initialized.");
      // Consider throwing an exception or returning a status
      return;
    }

    Pointer<Utf8> vocabUtf8 = nullptr;
    try {
      vocabUtf8 = vocabulary.toNativeUtf8();
      // Assuming _sttContext is Pointer<cactus_stt_context_t>
      // and cactus_stt_set_user_vocabulary expects Pointer<cactus_stt_context_t>, Pointer<Utf8>
      // The actual type for _sttContext in the binding might be Pointer<Void> or a specific Opaque type
      // depending on how ffigen interprets cactus_stt_context_t from cactus_ffi.h.
      // Let's assume the generated binding function will handle the specific context pointer type.
      _bindings.cactus_stt_set_user_vocabulary(_sttContext, vocabUtf8.cast());
      print("CactusSTTService: User vocabulary set to: $vocabulary");
    } catch (e) {
      print('Exception during setUserVocabulary: $e');
    } finally {
      if (vocabUtf8 != nullptr) {
        malloc.free(vocabUtf8);
      }
    }
  }

  /// Processes a chunk of audio data for transcription.
  ///
  /// [audioSamples]: A list of float audio samples (PCM 32-bit, 16kHz, mono).
  /// Returns `true` if processing is successful, `false` otherwise.
  Future<bool> processAudioChunk(List<double> audioSamples) async {
    if (!isInitialized) {
      print('STT Service not initialized.');
      return false;
    }
    if (audioSamples.isEmpty) {
      print('Audio samples list is empty.');
      return false; // Or true, if empty list is not an error
    }

    // Allocate memory for the audio samples and copy the data.
    // Note: `double` in Dart is typically 64-bit, STT expects float (32-bit).
    // The FFI layer for processAudio takes `const float*`, so we need Pointer<Float>.
    final Pointer<Float> samplesPtr = malloc.allocate<Float>(audioSamples.length);
    for (int i = 0; i < audioSamples.length; i++) {
      samplesPtr[i] = audioSamples[i]; // Dart double is implicitly converted to float here if needed by store operation.
    }

    try {
      final success = _bindings.cactus_stt_process_audio(
        _sttContext,
        samplesPtr,
        audioSamples.length,
      );
      return success;
    } catch (e) {
      print('Exception during audio processing: $e');
      return false;
    } finally {
      malloc.free(samplesPtr);
    }
  }

  /// Retrieves the full transcription result from the processed audio.
  ///
  /// Returns the transcribed text as a [String], or `null` if no transcription
  /// is available or an error occurs.
  Future<String?> getTranscription() async {
    if (!isInitialized) {
      print('STT Service not initialized.');
      return null;
    }

    Pointer<Utf8> transcriptionPtr = nullptr;
    try {
      transcriptionPtr = _bindings.cactus_stt_get_transcription(_sttContext);

      if (transcriptionPtr == nullptr) {
        // This can mean no transcription is ready yet, or an error occurred.
        // The C++ layer might log more details if it's an error.
        print('Failed to get transcription: cactus_stt_get_transcription returned nullptr.');
        return null;
      }

      final String transcription = transcriptionPtr.toDartString();
      return transcription;
    } catch (e) {
      print('Exception during transcription retrieval: $e');
      return null;
    } finally {
      // Free the string allocated by C using the provided C FFI function.
      if (transcriptionPtr != nullptr) {
        _bindings.cactus_free_string_c(transcriptionPtr.cast<Char>()); // Cast Pointer<Utf8> to Pointer<Char>
      }
    }
  }

  /// Processes a list of audio samples and returns the transcription,
  /// optionally applying advanced [SttOptions].
  ///
  /// Throws an [Exception] if STT is not initialized or if processing/transcription fails.
  /// Returns an empty string if transcription results in no text but processing was successful.
  Future<String> processAudioWithTranscriptionAndOptions(List<double> samples, {SttOptions? options}) async {
    if (!isInitialized) {
      throw Exception('STT Service not initialized. Call initialize() first.');
    }
    if (samples.isEmpty) {
      print('STT Service: Audio samples list is empty. Returning empty transcription.');
      return "";
    }

    // Convert List<double> to Pointer<Float> for FFI
    final samplesPtr = malloc.allocate<Float>(samples.length);
    for (int i = 0; i < samples.length; i++) {
      samplesPtr[i] = samples[i];
    }

    bool success;
    Pointer<cactus_stt_processing_params_c> paramsCPtr = nullptr; // Assuming ffigen names it this

    try {
      if (options != null) {
        // Allocate memory for the native params struct
        paramsCPtr = malloc.allocate<cactus_stt_processing_params_c>(sizeOf<cactus_stt_processing_params_c>());

        // Get default native params
        final defaultNativeParams = _bindings.cactus_stt_default_processing_params_c();

        // Copy defaults to our allocated pointer
        paramsCPtr.ref.n_threads = options.nThreads ?? defaultNativeParams.n_threads;
        paramsCPtr.ref.token_timestamps = options.tokenTimestamps ?? defaultNativeParams.token_timestamps;
        paramsCPtr.ref.temperature = options.temperature ?? defaultNativeParams.temperature; // Dart double will be converted to C float by FFI
        paramsCPtr.ref.speed_up = options.speedUp ?? defaultNativeParams.speed_up;
        paramsCPtr.ref.audio_ctx = options.audioCtx ?? defaultNativeParams.audio_ctx;
        paramsCPtr.ref.max_len = options.maxLen ?? defaultNativeParams.max_len;
        paramsCPtr.ref.max_tokens = options.maxTokens ?? defaultNativeParams.max_tokens;
        paramsCPtr.ref.no_context = options.noContext ?? defaultNativeParams.no_context;

        success = _bindings.cactus_stt_process_audio_with_params_c(
            _sttContext, // Already checked for nullptr by isInitialized
            samplesPtr,
            samples.length,
            paramsCPtr);
      } else {
        // Call the existing process audio if no specific options are given
        success = _bindings.cactus_stt_process_audio(
            _sttContext, // Already checked
            samplesPtr,
            samples.length);
      }

      if (!success) {
        throw Exception('STT processing failed at the native level.');
      }

      // Fetch transcription
      final transcriptPtr = _bindings.cactus_stt_get_transcription(_sttContext);
      if (transcriptPtr == nullptr) {
        // This could mean empty transcription or an error post-processing.
        // Depending on expected behavior, might throw or return empty.
        print('STT Service: cactus_stt_get_transcription returned nullptr after processing.');
        return "";
      }
      final transcript = transcriptPtr.toDartString();
      _bindings.cactus_free_string_c(transcriptPtr);
      return transcript;

    } catch (e) {
      print('STT Service: Exception during processAudioWithTranscriptionAndOptions: $e');
      rethrow; // Rethrow the caught exception
    } finally {
      malloc.free(samplesPtr);
      if (paramsCPtr != nullptr) {
        malloc.free(paramsCPtr);
      }
    }
  }

  /// Starts a new STT streaming session.
  ///
  /// Returns a [Stream<String>] for partial transcription results.
  /// The `onFinalResult` callback will be invoked when the stream is finished using [stopStreamingSTT].
  /// Optional `onStreamError` callback can be used for handling stream-specific errors.
  ///
  /// Throws an [Exception] if STT is not initialized or if another stream is already active.
  Future<Stream<String>> startStreamingSTT({
    SttOptions? options,
    required Function(String finalTranscript) onFinalResult,
    Function(Object error)? onStreamError,
  }) async {
    if (_isStreaming) {
      throw Exception("CactusSTTService: Another stream is already active. Call stopStreamingSTT() first.");
    }
    if (!isInitialized) {
      throw Exception('CactusSTTService: STT not initialized. Call initialize() first.');
    }

    _onStreamError = onStreamError;

    _partialTranscriptStreamController = StreamController<String>.broadcast();
    _finalTranscriptCompleter = Completer<String>();
    _finalTranscriptCompleter!.future.then(onFinalResult).catchError((e) {
      _onStreamError?.call(e);
    });


    Pointer<cactus_stt_processing_params_c> paramsCPtr = nullptr;
    final arena = Arena(); // For managing paramsCPtr if options are provided

    try {
      // Get default native params first, then override
      final defaultNativeParams = _bindings.cactus_stt_default_processing_params_c();
      paramsCPtr = arena.allocate<cactus_stt_processing_params_c>(sizeOf<cactus_stt_processing_params_c>());
      paramsCPtr.ref = defaultNativeParams; // Copy defaults

      if (options != null) {
        // Override with user-provided options
        if (options.nThreads != null) paramsCPtr.ref.n_threads = options.nThreads!;
        if (options.tokenTimestamps != null) paramsCPtr.ref.token_timestamps = options.tokenTimestamps!;
        if (options.temperature != null) paramsCPtr.ref.temperature = options.temperature!; // Assumes double can be assigned to float due to FFI handling
        if (options.speedUp != null) paramsCPtr.ref.speed_up = options.speedUp!;
        if (options.audioCtx != null) paramsCPtr.ref.audio_ctx = options.audioCtx!;
        if (options.maxLen != null) paramsCPtr.ref.max_len = options.maxLen!;
        if (options.maxTokens != null) paramsCPtr.ref.max_tokens = options.maxTokens!;
        if (options.noContext != null) paramsCPtr.ref.no_context = options.noContext!;
      }

      // Prepare payload for static callbacks
      final callbackPayload = _SttStreamCallbackPayload(_partialTranscriptStreamController!, _finalTranscriptCompleter!);
      _streamCallbackStableCell = StableCell.value(callbackPayload);
      final userData = _streamCallbackStableCell!.reference.toOpaque();

      _nativePartialCallbackPtr = Pointer.fromFunction<stt_partial_result_callback_c_t>(_staticPartialCallbackDispatcher, exceptionalReturn: null);
      _nativeFinalCallbackPtr = Pointer.fromFunction<stt_final_result_callback_c_t>(_staticFinalCallbackDispatcher, exceptionalReturn: null);

      final success = _bindings.cactus_stt_stream_start_c(
          _sttContext,
          paramsCPtr,
          _nativePartialCallbackPtr!,
          userData,
          _nativeFinalCallbackPtr!,
          userData
      );

      if (!success) {
        _streamCallbackStableCell?.dispose();
        _streamCallbackStableCell = null;
        _isStreaming = false; // Ensure flag is false
        _partialTranscriptStreamController?.close();
        if (!(_finalTranscriptCompleter?.isCompleted == true)) {
           _finalTranscriptCompleter?.completeError(Exception("Failed to start STT stream at native layer."));
        }
        throw Exception("Failed to start STT stream at native layer.");
      }
      _isStreaming = true;

      // Clean up StableCell when the final completer finishes (either success or error)
      _finalTranscriptCompleter!.future.whenComplete(() {
        _streamCallbackStableCell?.dispose();
        _streamCallbackStableCell = null;
         // Partial controller is closed by the final callback dispatcher
      });

      return _partialTranscriptStreamController!.stream;

    } catch (e) {
      _streamCallbackStableCell?.dispose(); // Ensure disposal on any error
      _streamCallbackStableCell = null;
      _isStreaming = false;
      _partialTranscriptStreamController?.close();
      if (!(_finalTranscriptCompleter?.isCompleted == true)) {
         _finalTranscriptCompleter?.completeError(e);
      }
      rethrow;
    } finally {
        arena.releaseAll(); // Release memory allocated by Arena for paramsCPtr
    }
  }

  /// Feeds a chunk of audio data (PCM 32-bit float samples) to the active STT stream.
  ///
  /// Throws an [Exception] if the stream is not active or if an error occurs at the native level.
  Future<void> feedAudioChunk(List<double> pcmF32Samples) async {
    if (!_isStreaming || !isInitialized) {
        throw Exception("CactusSTTService: Stream not active or STT not initialized. Cannot feed audio chunk.");
    }
    if (pcmF32Samples.isEmpty) return; // Nothing to feed

    final samplesPtr = malloc.allocate<Float>(pcmF32Samples.length);
    try {
        for (int i = 0; i < pcmF32Samples.length; i++) {
            samplesPtr[i] = pcmF32Samples[i];
        }
        final success = _bindings.cactus_stt_stream_feed_audio_c(
            _sttContext,
            samplesPtr,
            pcmF32Samples.length);
        if (!success) {
            throw Exception("CactusSTTService: Failed to feed audio chunk to native layer.");
        }
    } finally {
        malloc.free(samplesPtr);
    }
  }

  /// Signals the end of the audio stream and requests final transcription.
  ///
  /// Returns a [Future<String>] that completes with the final transcription.
  /// Throws an [Exception] if the stream is not active or if finalization fails.
  Future<String> stopStreamingSTT() async {
    if (!_isStreaming || !isInitialized) {
        if (_finalTranscriptCompleter != null && !_finalTranscriptCompleter!.isCompleted) {
            final err = Exception("CactusSTTService: Stream not active or STT not initialized when trying to stop.");
            _finalTranscriptCompleter!.completeError(err);
            _onStreamError?.call(err); // Also call direct error handler if provided
            return _finalTranscriptCompleter!.future; // Return the already errored future
        } else if (_finalTranscriptCompleter == null) {
             return Future.error(Exception("CactusSTTService: Stream not active and no stream was ever started."));
        }
        // If completer is already completed, just return its future
        return _finalTranscriptCompleter!.future;
    }

    _isStreaming = false; // Mark as not streaming immediately

    final success = _bindings.cactus_stt_stream_finish_c(_sttContext);

    // The final result is delivered via the _staticFinalCallbackDispatcher,
    // which completes _finalTranscriptCompleter.
    // If finish_c failed, the completer might not be completed by the callback.
    if (!success && !_finalTranscriptCompleter!.isCompleted) {
        final err = Exception("CactusSTTService: Failed to finalize STT stream at native layer.");
         _finalTranscriptCompleter!.completeError(err);
         _onStreamError?.call(err);
    }

    // Native function pointers are Dart closures; no manual free needed.
    // _nativePartialCallbackPtr and _nativeFinalCallbackPtr are effectively managed by Dart's GC
    // once they are no longer referenced after the stream completes.
    // The StableCell holding the payload is disposed via _finalTranscriptCompleter.future.whenComplete.

    return _finalTranscriptCompleter!.future;
  }


  /// Frees the STT context and associated native resources.
  ///
  /// It's important to call this when the STT service is no longer needed
  /// to prevent memory leaks.
  Future<void> free() async {
    if (_isStreaming) {
      try {
        await stopStreamingSTT(); // Attempt to gracefully stop any active stream
      } catch (e) {
        print("CactusSTTService: Error stopping stream during free: $e");
        // Ensure controllers are closed even if stopStreamingSTT failed or threw before completing them
        if (_partialTranscriptStreamController != null && !_partialTranscriptStreamController!.isClosed) {
          _partialTranscriptStreamController!.close();
        }
        if (_finalTranscriptCompleter != null && !_finalTranscriptCompleter!.isCompleted) {
          _finalTranscriptCompleter!.completeError(Exception("STTService disposed during active stream."));
        }
         _streamCallbackStableCell?.dispose(); // Ensure stable cell is disposed
         _streamCallbackStableCell = null;
      }
    } else {
      // If not streaming, but controllers exist from a previous failed stream start, clean them up.
       _partialTranscriptStreamController?.close();
       if (_finalTranscriptCompleter != null && !_finalTranscriptCompleter!.isCompleted) {
          _finalTranscriptCompleter!.completeError(Exception("STTService disposed."));
       }
        _streamCallbackStableCell?.dispose();
        _streamCallbackStableCell = null;
    }
    _isStreaming = false;


    if (!isInitialized) {
      print('STT Service not initialized or already freed.');
      return;
    }

    try {
      _bindings.cactus_stt_free(_sttContext);
      _sttContext = nullptr; // Mark as freed
    } catch (e) {
      print('Exception during STT free: $e');
      // Even on exception, mark as freed to prevent reuse of potentially invalid context.
      _sttContext = nullptr;
    }
  }
}

// Example of how ffigen might generate the Opaque type if not explicitly defined.
// This is just for illustrative purposes; the actual type comes from the generated bindings.
// class cactus_stt_context_t extends Opaque {}
// If cactus_stt_context_t is defined as `typedef struct cactus_stt_context cactus_stt_context_t;`
// and `struct cactus_stt_context` is not exposed, ffigen treats it as opaque.
// If `cactus_ffi.h` had `typedef void* cactus_stt_context_t;`, it would also be `Pointer<Void>` then `Pointer<Opaque>`.
// The key is that `cactus_stt_context_t` in Dart will be a `Pointer<cactus_stt_context_t>` where
// `cactus_stt_context_t` itself is a Dart type representing the native struct (often Opaque).
