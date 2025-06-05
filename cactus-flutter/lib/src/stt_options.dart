// cactus-flutter/lib/src/stt_options.dart

/// Configuration options for Speech-to-Text (STT) processing.
///
/// Use this class to customize the behavior of the STT engine.
/// For any parameter not explicitly set, a default value from the underlying
/// STT engine will be used.
class SttOptions {
  /// Number of threads to use for STT processing.
  /// Defaults to a value chosen by the native STT engine (e.g., 4).
  final int? nThreads;

  /// Whether to enable token-level timestamps.
  /// Default: false.
  final bool? tokenTimestamps;

  /// Temperature for sampling during transcription.
  /// Higher values increase randomness.
  /// Default: 0.0 (deterministic).
  final double? temperature;

  /// Whether to attempt to speed up audio processing (e.g., 2x via ptdb).
  /// This might affect accuracy.
  /// Default: false.
  final bool? speedUp;

  /// Audio context size in milliseconds (0 for full context).
  /// Can be reduced for performance on some devices.
  /// Default: 0.
  final int? audioCtx;

  /// Maximum segment length in characters.
  /// 0 means no limit.
  /// Default: 0.
  final int? maxLen;

  /// Maximum tokens per segment.
  /// 0 means no limit.
  /// Default: 0.
  final int? maxTokens;

  /// If true, the STT engine will not use context from previous audio segments.
  /// This is important for controlling how context is maintained, especially
  /// during streaming or when processing independent audio chunks.
  /// Default: true (meaning no context is carried over by default unless
  /// specifically managed by streaming logic or other settings).
  final bool? noContext;

  /// Creates an instance of STT options.
  ///
  /// Only parameters that are set will override the engine's defaults.
  SttOptions({
    this.nThreads,
    this.tokenTimestamps,
    this.temperature,
    this.speedUp,
    this.audioCtx,
    this.maxLen,
    this.maxTokens,
    this.noContext,
  });
}
