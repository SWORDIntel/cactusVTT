// AudioInputModule.swift
import Foundation
import AVFoundation // For AVAudioSession and audio format conversion
import React // For RCTEventEmitter, RCTPromiseResolveBlock, etc.

// Define SttOptionsIOS struct (mirrors JS SttOptions and C FFI struct)
// This could also be in a separate .swift file if preferred for organization.
struct SttOptionsIOS {
    var nThreads: Int32?
    var tokenTimestamps: Bool?
    var temperature: Float?
    var speedUp: Bool?
    var audioCtx: Int32?
    var maxLen: Int32?
    var maxTokens: Int32?
    var noContext: Bool?
    // Language and translate are part of STTAdvancedParams in C++,
    // but not currently in cactus_stt_processing_params_c.
    // If they were, they'd be added here.
    // var language: String?
    // var translate: Bool?

    init(fromDictionary dict: [String: Any]) {
        self.nThreads = dict["nThreads"] as? Int32
        self.tokenTimestamps = dict["tokenTimestamps"] as? Bool
        // React Native might pass numbers as Double or NSNumber, so handle conversion carefully.
        if let temp = dict["temperature"] as? NSNumber {
            self.temperature = temp.floatValue
        } else if let tempDouble = dict["temperature"] as? Double {
            self.temperature = Float(tempDouble)
        }
        self.speedUp = dict["speedUp"] as? Bool
        self.audioCtx = dict["audioCtx"] as? Int32
        self.maxLen = dict["maxLen"] as? Int32
        self.maxTokens = dict["maxTokens"] as? Int32 // Corrected from Bool based on C struct
        self.noContext = dict["noContext"] as? Bool
        // self.language = dict["language"] as? String
        // self.translate = dict["translate"] as? Bool
    }
}

// Define STTError enum if not already globally available from another module
// For simplicity, defining it here if it's specific to this module's STT operations.
// If shared from cactus-ios SDK, this might not be needed.
enum STTError: Error, LocalizedError {
    case notInitialized
    case processingFailed(String)
    case transcriptionFailed
    case permissionDenied
    case audioRecordingFailed(Error) // Keep existing errors
    case alreadyCapturing // Keep existing errors
    case unknown(String) // Keep existing errors
    case featureNotImplemented(String) // Keep existing errors

    case streamAlreadyActive
    case streamNotActive
    case streamStartFailed
    case streamFinishFailed
    case streamFeedAudioFailed
    case invalidAudioData

    public var errorDescription: String? {
        switch self {
        case .notInitialized: return "STT Service is not initialized."
        case .processingFailed(let msg): return "STT processing failed: \(msg)"
        case .transcriptionFailed: return "STT transcription failed to produce text."
        case .permissionDenied: return "Microphone permission was denied."
        case .audioRecordingFailed(let err): return "Audio recording failed: \(err.localizedDescription)"
        case .alreadyCapturing: return "Audio capture is already in progress."
        case .unknown(let msg): return "An unknown STT error occurred: \(msg)"
        case .featureNotImplemented(let featureName): return "\(featureName) is not yet implemented."
        case .streamAlreadyActive: return "A streaming session is already active."
        case .streamNotActive: return "No active streaming session found."
        case .streamStartFailed: return "Failed to start the STT stream."
        case .streamFinishFailed: return "Failed to finalize the STT stream."
        case .streamFeedAudioFailed: return "Failed to feed audio to the STT stream."
        case .invalidAudioData: return "Invalid audio data provided."
        }
    }
}


@objc(AudioInputModule)
class AudioInputModule: RCTEventEmitter, AVAudioRecorderDelegate {

    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    private var sttContext: OpaquePointer? // Renamed from UnsafeMutableRawPointer? to OpaquePointer? for C FFI types
    private var isSttInitialized: Bool = false // Explicit flag

    // --- Streaming State Members ---
    private var streamUserSelfData: UnsafeMutableRawPointer?
    public var isStreamingActiveRN: Bool = false
    // --- End Streaming State Members ---

    override init() {
        super.init()
    }

    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return true // Typically true if you interact with UIKit or main-thread-only APIs
    }

    override func supportedEvents() -> [String]! {
        return ["onAudioData", "onError", "onSTTPartialResult", "onSTTFinalResult", "onSTTStreamError"]
    }

    // MARK: - Audio Recording Methods (Existing)
    @objc
    func requestPermissions(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if granted {
                resolve(true)
            } else {
                reject("permission_denied", "Microphone permission denied", nil)
            }
        }
    }

    @objc
    func startRecording(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // ... (existing startRecording implementation) ...
        let audioSession = AVAudioSession.sharedInstance()
        do {
          try audioSession.setCategory(.playAndRecord, mode: .default)
          try audioSession.setActive(true)

          let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          self.audioFilename = documentsPath.appendingPathComponent("recording.m4a")

          guard let audioFilename = self.audioFilename else {
            reject("file_error", "Could not create audio file", nil)
            return
          }

          let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), // Using AAC for m4a
            AVSampleRateKey: 16000, // Standard for Whisper
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue // Medium for smaller file size
          ]

          self.audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
          self.audioRecorder?.delegate = self
          self.audioRecorder?.record()
          resolve("Recording started")
        } catch {
          reject("start_recording_failed", "Failed to start recording: \(error.localizedDescription)", error)
        }
    }

    @objc
    func stopRecording(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // ... (existing stopRecording implementation, ensures onAudioData event is sent) ...
        guard let recorder = self.audioRecorder else {
          reject("not_recording", "No recording in progress", nil)
          return
        }

        recorder.stop()
        let audioSession = AVAudioSession.sharedInstance()
        do {
          try audioSession.setActive(false)
          if let audioFilename = self.audioFilename {
            if FileManager.default.fileExists(atPath: audioFilename.path) {
                 let attributes = try FileManager.default.attributesOfItem(atPath: audioFilename.path)
                 let fileSize = attributes[FileAttributeKey.size] as? NSNumber
                 if (fileSize?.intValue ?? 0) > 0 {
                     self.sendEvent(withName: "onAudioData", body: ["filePath": audioFilename.absoluteString])
                     resolve(["filePath": audioFilename.absoluteString, "fileSize": fileSize?.intValue ?? 0])
                 } else {
                     reject("file_error", "Recorded file is empty or invalid.", nil)
                 }
            } else {
                reject("file_error", "Recorded file not found.", nil)
            }
          } else {
            reject("file_error", "Audio filename not found", nil)
          }
        } catch {
          reject("stop_recording_failed", "Failed to stop recording: \(error.localizedDescription)", error)
        }
        self.audioRecorder = nil
        self.audioFilename = nil
    }

    // MARK: - AVAudioRecorderDelegate Methods
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
      if !flag {
        sendEvent(withName: "onError", body: ["message": "Recording finished unsuccessfully (delegate)"])
      }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
      if let error = error {
        sendEvent(withName: "onError", body: ["message": "Recording encode error: \(error.localizedDescription)"])
      }
    }

    // MARK: - STT Methods (Initialization, Vocabulary, Non-Streaming Processing)

    @objc(initSTT:language:resolver:rejecter:)
    func initSTT(_ modelPath: String, language: String? = "en", resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        print("[AudioInputModule] initSTT called with modelPath: \(modelPath), language: \(language ?? "en")")
        if self.sttContext != nil {
            RN_STT_free(self.sttContext) // Assumes RN_STT_free is in bridging header
            self.sttContext = nil
        }
        let langCStr = (language ?? "en").cString(using: .utf8)
        if let modelPathCStr = modelPath.cString(using: .utf8) {
            self.sttContext = RN_STT_init(modelPathCStr, langCStr) // Assumes RN_STT_init is in bridging header
            if self.sttContext != nil {
                self.isSttInitialized = true
                resolve("STT initialized successfully")
            } else {
                self.isSttInitialized = false
                reject("stt_init_failed", "Failed to initialize STT model (RN_STT_init returned null)", nil)
            }
        } else {
            self.isSttInitialized = false
            reject("stt_init_failed", "Failed to convert modelPath to C string", nil)
        }
    }

    @objc(setUserVocabulary:resolver:rejecter:)
    func setUserVocabulary(_ vocabulary: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let context = sttContext, isSttInitialized else {
            reject("stt_error", "STT not initialized", nil)
            return
        }
        if let vocabularyCString = vocabulary.cString(using: .utf8) {
            RN_STT_setUserVocabulary(context, vocabularyCString) // Assumes RN_STT_setUserVocabulary is in bridging header
            resolve(nil)
        } else {
            reject("vocab_error", "Failed to convert vocabulary to C string", nil)
        }
    }

    // Helper to convert file to [Float] - Placeholder, needs actual implementation
    private func loadAudioSamplesFromFile(filePath: String) throws -> [Float] {
        // This is a complex task: needs to read audio file (e.g. m4a, wav),
        // decode it, resample to 16kHz mono, and convert to Float array.
        // For this example, we'll return an empty array and focus on the FFI options part.
        // In a real app, use AVFoundation or a third-party library.
        print("[AudioInputModule] Warning: loadAudioSamplesFromFile is a placeholder.")
        // To make it runnable without full audio loading, return empty or a tiny dummy sample.
        // If returning empty, ensure calling code handles it.
        // For testing the options flow, we can proceed with an empty array,
        // though native layer might complain or do nothing.
        // Let's assume for testing it might pass an empty buffer to native code.
        return []
    }

    @objc(processAudioFileWithOptions:options:resolver:rejecter:)
    func processAudioFileWithOptions(filePath: String, options: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let context = sttContext, isSttInitialized else {
            reject("stt_error", "STT not initialized", nil)
            return
        }

        let samples: [Float]
        do {
            samples = try loadAudioSamplesFromFile(filePath: filePath)
            // If sample loading is critical and might be empty, handle here:
            // if samples.isEmpty {
            //    resolve("") // Or reject based on desired behavior for empty audio
            //    return
            // }
        } catch {
            reject("audio_load_error", "Failed to load audio samples from file: \(error.localizedDescription)", error)
            return
        }

        var nativeParams: cactus_stt_processing_params_c_t = cactus_stt_default_processing_params_c()
        let swiftOptions = SttOptionsIOS(fromDictionary: options)

        if let nThreads = swiftOptions.nThreads { nativeParams.n_threads = nThreads }
        if let tokenTimestamps = swiftOptions.tokenTimestamps { nativeParams.token_timestamps = tokenTimestamps }
        if let temperature = swiftOptions.temperature { nativeParams.temperature = temperature }
        if let speedUp = swiftOptions.speedUp { nativeParams.speed_up = speedUp }
        if let audioCtx = swiftOptions.audioCtx { nativeParams.audio_ctx = audioCtx }
        if let maxLen = swiftOptions.maxLen { nativeParams.max_len = maxLen }
        if let maxTokens = swiftOptions.maxTokens { nativeParams.max_tokens = maxTokens }
        if let noContext = swiftOptions.noContext { nativeParams.no_context = noContext }

        let success = samples.withUnsafeBufferPointer { bufferPtr -> Bool in
            let baseAddress = bufferPtr.baseAddress // Can be nil if samples is empty
            return cactus_stt_process_audio_with_params_c(context, baseAddress, UInt32(samples.count), &nativeParams)
        }

        if success {
            if let transcriptCString = cactus_stt_get_transcription(context) {
                let transcript = String(cString: transcriptCString)
                cactus_free_string_c(transcriptCString)
                resolve(transcript)
            } else {
                resolve("")
            }
        } else {
            reject("stt_processing_error", "STT processing failed with options", nil)
        }
    }


    @objc(processAudioFile:resolver:rejecter:)
    func processAudioFile(_ filePath: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // Call the new method with nil options for default behavior
        processAudioFileWithOptions(filePath: filePath, options: [:], resolver: resolve, rejecter: reject)
    }

    @objc(releaseSTT:rejecter:)
    func releaseSTT(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        print("[AudioInputModule] releaseSTT called")
        if let context = sttContext {
            RN_STT_free(context)
            self.sttContext = nil
            self.isSttInitialized = false
            resolve("STT released successfully")
        } else {
            self.isSttInitialized = false // Ensure flag is consistent
            resolve("STT already released or not initialized")
        }
    }

    // MARK: - Streaming STT Methods
    @objc(startStreamingSTTNative:resolver:rejecter:)
    func startStreamingSTTNative(options: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let context = sttContext, isSttInitialized else {
            reject("stt_error", "STT not initialized", nil); return
        }
        if isStreamingActiveRN {
            reject("stt_error", "Stream already active", nil); return
        }

        var nativeParams: cactus_stt_processing_params_c_t = cactus_stt_default_processing_params_c()
        let swiftOptions = SttOptionsIOS(fromDictionary: options)
        if let nThreads = swiftOptions.nThreads { nativeParams.n_threads = nThreads }
        if let tokenTimestamps = swiftOptions.tokenTimestamps { nativeParams.token_timestamps = tokenTimestamps }
        if let temperature = swiftOptions.temperature { nativeParams.temperature = temperature }
        if let speedUp = swiftOptions.speedUp { nativeParams.speed_up = speedUp }
        if let audioCtx = swiftOptions.audioCtx { nativeParams.audio_ctx = audioCtx }
        if let maxLen = swiftOptions.maxLen { nativeParams.max_len = maxLen }
        if let maxTokens = swiftOptions.maxTokens { nativeParams.max_tokens = maxTokens }
        if let noContext = swiftOptions.noContext { nativeParams.no_context = noContext }

        self.streamUserSelfData = Unmanaged.passRetained(self).toOpaque()

        let cPartialCallback: stt_partial_result_callback_c_t = { (transcriptCString, userData) -> Void in
            guard let userData = userData, let transcriptCString = transcriptCString else { return }
            let moduleInstance = Unmanaged<AudioInputModule>.fromOpaque(userData).takeUnretainedValue()
            let transcript = String(cString: transcriptCString)
            moduleInstance.sendEvent(withName: "onSTTPartialResult", body: transcript)
        }

        let cFinalCallback: stt_final_result_callback_c_t = { (transcriptCString, userData) -> Void in
            guard let userData = userData else { return }
            let moduleInstance = Unmanaged<AudioInputModule>.fromOpaque(userData).takeRetainedValue()

            var resultBody: [String: Any] = [:]
            if let cstr = transcriptCString {
                resultBody["transcript"] = String(cString: cstr)
            } else {
                resultBody["error"] = STTError.transcriptionFailed.localizedDescription
            }
            moduleInstance.sendEvent(withName: "onSTTFinalResult", body: resultBody)

            moduleInstance.isStreamingActiveRN = false
            moduleInstance.streamUserSelfData = nil
        }

        let success = cactus_stt_stream_start_c(
            context, &nativeParams,
            cPartialCallback, self.streamUserSelfData,
            cFinalCallback, self.streamUserSelfData
        )

        if success {
            self.isStreamingActiveRN = true
            resolve(nil)
        } else {
            if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
            reject("stt_error", "Failed to start STT stream (native)", nil)
        }
    }

    @objc(feedAudioChunkNative:resolver:rejecter:)
    func feedAudioChunkNative(audioDataBase64: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let context = sttContext, isSttInitialized, isStreamingActiveRN else {
            reject("stt_error", "Stream not active or STT not initialized", nil); return
        }
        guard let audioData = Data(base64Encoded: audioDataBase64) else {
            reject("stt_error", "Invalid base64 audio data for chunk", nil); return
        }

        let samples: [Float] = audioData.withUnsafeBytes { bufferPtr -> [Float] in
            guard let int16Ptr = bufferPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return [] }
            let int16Buffer = UnsafeBufferPointer(start: int16Ptr, count: audioData.count / MemoryLayout<Int16>.size)
            return int16Buffer.map { Float($0) / 32768.0 }
        }

        if samples.isEmpty && audioData.count > 0 { // check if conversion failed for non-empty data
             reject("stt_error", "Failed to convert audio data to Float samples", nil); return
        }

        let success = samples.withUnsafeBufferPointer { bufferPointer -> Bool in
            let baseAddress = bufferPointer.baseAddress
            return cactus_stt_stream_feed_audio_c(context, baseAddress, UInt32(samples.count))
        }

        if success { resolve(nil) }
        else { reject("stt_error", "Failed to feed audio chunk (native)", nil) }
    }

    @objc(stopStreamingSTTNative:rejecter:)
    func stopStreamingSTTNative(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let context = sttContext, isSttInitialized else {
            if isStreamingActiveRN { // Stream was active but context lost? Clean up Swift state.
                 if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
                 self.sendEvent(withName: "onSTTFinalResult", body: ["error": STTError.notInitialized.localizedDescription])
            }
            self.isStreamingActiveRN = false
            reject("stt_error", "STT not initialized, cannot stop stream.", nil)
            return
        }

        guard self.isStreamingActiveRN else {
            // If stop is called when not streaming, resolve successfully as a no-op.
            // Or reject if this state is considered an error by the caller.
            print("[AudioInputModule] stopStreamingSTTNative called but not actively streaming.")
            resolve(nil)
            return
        }

        let success = cactus_stt_stream_finish_c(context)

        if !success {
            // If native finish fails, the C callback might not fire.
            // We must ensure cleanup and error reporting.
            if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
            self.isStreamingActiveRN = false
            self.sendEvent(withName: "onSTTFinalResult", body: ["error": STTError.streamFinishFailed.localizedDescription])
            reject("stt_error", "Failed to stop STT stream (native)", nil)
        } else {
            // Success: Native call initiated finish. The C callback will handle actual cleanup of user_data and isStreamingActiveRN.
            resolve(nil)
        }
    }
}
