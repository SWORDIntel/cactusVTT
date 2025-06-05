// cactus-ios/Cactus/SttOptions.swift

import Foundation

/// Configuration options for Speech-to-Text (STT) processing in the Native iOS SDK.
///
/// Use this struct to customize the behavior of the STT engine.
/// For any parameter not explicitly set (i.e., left as `nil`), a default value
/// from the underlying STT engine will be used.
public struct SttOptions {
    /// Number of threads to use for STT processing.
    /// If `nil`, uses the engine's default (e.g., 4).
    public var nThreads: Int32?

    /// Whether to enable token-level timestamps.
    /// If `nil`, uses the engine's default (false).
    public var tokenTimestamps: Bool?

    /// Temperature for sampling during transcription.
    /// Higher values increase randomness.
    /// If `nil`, uses the engine's default (0.0 for deterministic).
    public var temperature: Float?

    /// Whether to attempt to speed up audio processing (e.g., 2x via ptdb).
    /// This might affect accuracy.
    /// If `nil`, uses the engine's default (false).
    public var speedUp: Bool?

    /// Audio context size in milliseconds (0 for full context).
    /// Can be reduced for performance on some devices.
    /// If `nil`, uses the engine's default (0).
    public var audioCtx: Int32?

    /// Maximum segment length in characters.
    /// 0 means no limit.
    /// If `nil`, uses the engine's default (0).
    public var maxLen: Int32?

    /// Maximum tokens per segment.
    /// 0 means no limit.
    /// If `nil`, uses the engine's default (0).
    public var maxTokens: Int32?

    /// If true, the STT engine will not use context from previous audio segments.
    /// This is important for controlling how context is maintained, especially
    /// during streaming or when processing independent audio chunks.
    /// If `nil`, uses the engine's default (true, meaning no context carried over by default
    /// unless managed by streaming logic or other settings).
    public var noContext: Bool?

    /// Creates an instance of STT options.
    ///
    /// Only parameters that are set (non-`nil`) will be used to override
    /// the STT engine's defaults.
    public init(
        nThreads: Int32? = nil,
        tokenTimestamps: Bool? = nil,
        temperature: Float? = nil,
        speedUp: Bool? = nil,
        audioCtx: Int32? = nil,
        maxLen: Int32? = nil,
        maxTokens: Int32? = nil,
        noContext: Bool? = nil
    ) {
        self.nThreads = nThreads
        self.tokenTimestamps = tokenTimestamps
        self.temperature = temperature
        self.speedUp = speedUp
        self.audioCtx = audioCtx
        self.maxLen = maxLen
        self.maxTokens = maxTokens
        self.noContext = noContext
    }
}
