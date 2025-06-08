// AudioInputModule.swift
import Foundation
import AVFoundation
import React // For RCTEventEmitter, RCTPromiseResolveBlock, etc.

// Define SttOptionsIOS struct (mirrors JS SttOptions and C FFI struct)
struct SttOptionsIOS {
    var nThreads: Int32?
    var tokenTimestamps: Bool?
    var temperature: Float?
    var speedUp: Bool?
    var audioCtx: Int32?
    var maxLen: Int32?
    var maxTokens: Int32?
    var noContext: Bool?
    // var language: String? // Language for initSTT, not per-call options here
    // var translate: Bool?  // Translate for initSTT or a dedicated method

    init(fromDictionary dict: [String: Any]) {
        self.nThreads = dict["nThreads"] as? Int32
        self.tokenTimestamps = dict["tokenTimestamps"] as? Bool
        if let temp = dict["temperature"] as? NSNumber {
            self.temperature = temp.floatValue
        } else if let tempDouble = dict["temperature"] as? Double {
            self.temperature = Float(tempDouble)
        }
        self.speedUp = dict["speedUp"] as? Bool
        self.audioCtx = dict["audioCtx"] as? Int32
        self.maxLen = dict["maxLen"] as? Int32
        self.maxTokens = dict["maxTokens"] as? Int32
        self.noContext = dict["noContext"] as? Bool
    }
}

enum STTError: Error, LocalizedError {
    case notInitialized
    case processingFailed(String)
    case transcriptionFailed
    case permissionDenied
    case audioRecordingFailed(Error)
    case alreadyCapturing // For non-streaming recording
    case unknown(String)
    case featureNotImplemented(String)
    case streamAlreadyActive
    case streamNotActive
    case streamStartFailed
    case streamFinishFailed
    case streamFeedAudioFailed
    case invalidAudioData
    case audioEngineError(String)

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
        case .audioEngineError(let msg): return "Audio engine error: \(msg)"
        }
    }
}


@objc(AudioInputModule)
class AudioInputModule: RCTEventEmitter, AVAudioRecorderDelegate {

    private var audioRecorder: AVAudioRecorder? // For non-streaming recording
    private var audioFilename: URL?

    // STT Properties
    private var sttContext: OpaquePointer?
    private var isSttInitialized: Bool = false

    // Streaming State
    private let audioEngine = AVAudioEngine()
    private var audioInputNode: AVAudioInputNode?
    private var streamUserSelfData: UnsafeMutableRawPointer?
    @objc public var isStreamingActiveRN: Bool = false // @objc for potential KVO from JS if needed, though direct calls are primary

    override init() {
        super.init()
        setupAudioEngine() // Initial setup for AVAudioEngine
    }

    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return false // Can be initialized on background thread
    }

    override func supportedEvents() -> [String]! {
        return ["onAudioData", "onError", "onSTTPartialResult", "onSTTFinalResult", "onSTTStreamError"]
    }

    // MARK: - Audio Engine Setup
    private func setupAudioEngine() {
        self.audioInputNode = audioEngine.inputNode
        // Basic session setup, can be refined.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("[AudioInputModule] Failed to set up audio session: \(error)")
            // This error could be propagated to JS if critical for module init.
        }
    }

    private func installTapAndPrepareEngine() throws {
        guard let inputNode = self.audioInputNode else { throw STTError.audioEngineError("Audio input node not available.") }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Desired format for Whisper.cpp: 16kHz, mono, Float32
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat!)! // Handle optional properly in real app

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self, self.isStreamingActiveRN else { return }

            // Convert buffer to desired format (16kHz mono Float32)
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat!, frameCapacity: AVAudioFrameCount(desiredFormat!.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate))!
            var error: NSError? = nil

            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                print("[AudioInputModule] Error converting audio buffer: \(error)")
                // self.sendEvent(withName: "onSTTStreamError", body: ["error": "Audio conversion error: \(error.localizedDescription)"])
                return
            }

            let samples = self.convertPCMBufferToFloatArray(buffer: pcmBuffer)
            if !samples.isEmpty {
                self.onAudioData(samples)
            }
        }
        audioEngine.prepare()
    }

    private func convertPCMBufferToFloatArray(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let floatChannelData = buffer.floatChannelData, buffer.format.commonFormat == .pcmFormatFloat32 else {
            print("[AudioInputModule] Buffer format is not Float32 or channel data is nil.")
            return []
        }
        // Assuming mono, take first channel
        let channelData = floatChannelData[0]
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }

    private func _stopMicCapture() {
        DispatchQueue.main.async { // Ensure UI related audio stops are on main if they have implications
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
                self.audioInputNode?.removeTap(onBus: 0)
                print("[AudioInputModule] Audio engine stopped and tap removed.")
            }
            // Deactivate audio session if no longer needed by other parts of the app
            // do { try AVAudioSession.sharedInstance().setActive(false) } catch { print("[AudioInputModule] Failed to deactivate audio session.") }
        }
    }

    // This is called by the tap
    private func onAudioData(_ samples: [Float]) {
        guard isStreamingActiveRN, let context = sttContext else { return }

        let success = samples.withUnsafeBufferPointer { bufferPtr -> Bool in
            guard let baseAddress = bufferPtr.baseAddress else { return cactus_stt_stream_feed_audio_c(context, nil, 0) }
            return cactus_stt_stream_feed_audio_c(context, baseAddress, UInt32(samples.count))
        }
        if !success {
            print("[AudioInputModule] Error feeding audio chunk to native STT stream.")
            // This error should ideally be propagated to the JS layer via an event
            self.sendEvent(withName: "onSTTStreamError", body: ["error": STTError.streamFeedAudioFailed.localizedDescription])
            // Optionally, stop the stream if feed fails critically
            // self.stopSttStream(isCalledFromError: true)
        }
    }


    // MARK: - Existing Non-Streaming Methods (requestPermissions, startRecording, stopRecording, AVAudioRecorderDelegate)
    // ... (These remain largely unchanged but ensure they don't conflict with AVAudioEngine state if used simultaneously) ...
    @objc
    func requestPermissions(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if granted { resolve(true) } else { reject("permission_denied", "Microphone permission denied", nil) }
        }
    }

    @objc
    func startRecording(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        if isStreamingActiveRN { reject("stream_active", "Cannot start recording while streaming.", nil); return }
        // ... (rest of existing startRecording using AVAudioRecorder)
        let audioSession = AVAudioSession.sharedInstance()
        do {
          try audioSession.setCategory(.playAndRecord, mode: .default)
          try audioSession.setActive(true)
          let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          self.audioFilename = documentsPath.appendingPathComponent("recordingForFileProcessing.m4a") // Different name
          guard let audioFilename = self.audioFilename else {
            reject("file_error", "Could not create audio file for recording.", nil); return
          }
          let settings = [ AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue ]
          self.audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
          self.audioRecorder?.delegate = self
          self.audioRecorder?.record()
          resolve("Buffered recording started for file processing.")
        } catch {
          reject("start_recording_failed", "Failed to start buffered recording: \(error.localizedDescription)", error)
        }
    }

    @objc
    func stopRecording(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // ... (existing stopRecording using AVAudioRecorder, sends "onAudioData" with filePath) ...
        guard let recorder = self.audioRecorder else { reject("not_recording", "No buffered recording in progress", nil); return }
        recorder.stop()
        let audioSession = AVAudioSession.sharedInstance(); do { try audioSession.setActive(false) } catch { /* log error */ }
        if let audioFilename = self.audioFilename, FileManager.default.fileExists(atPath: audioFilename.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: audioFilename.path)
            let fileSize = attributes?[FileAttributeKey.size] as? NSNumber
            self.sendEvent(withName: "onAudioData", body: ["filePath": audioFilename.absoluteString]) // This event is for processAudio
            resolve(["filePath": audioFilename.absoluteString, "fileSize": fileSize?.intValue ?? 0])
        } else { reject("file_error", "Recorded file not found or empty.", nil) }
        self.audioRecorder = nil; self.audioFilename = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { /* ... */ }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { /* ... */ }


    // MARK: - STT Methods
    @objc(initSTT:language:resolver:rejecter:)
    func initSTT(_ modelPath: String, language: String? = "en", resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        NSLog("[AudioInputModule] Swift: initSTT called with modelPath: %@", modelPath)
        // ... (existing initSTT implementation, ensure isSttInitialized is set) ...
        print("[AudioInputModule] initSTT called with modelPath: \(modelPath), language: \(language ?? "en")")
        if self.sttContext != nil { RN_STT_free(self.sttContext); self.sttContext = nil }
        let langCStr = (language ?? "en").cString(using: .utf8)
        if let modelPathCStr = modelPath.cString(using: .utf8) {
            self.sttContext = RN_STT_init(modelPathCStr, langCStr)
            if self.sttContext != nil { self.isSttInitialized = true; resolve("STT initialized successfully") }
            else { self.isSttInitialized = false; reject("stt_init_failed", "RN_STT_init returned null", nil) }
        } else { self.isSttInitialized = false; reject("stt_init_failed", "Failed to convert modelPath to C string", nil) }
    }

    @objc(setUserVocabulary:resolver:rejecter:)
    func setUserVocabulary(_ vocabulary: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // ... (existing setUserVocabulary implementation) ...
        guard let context = sttContext, isSttInitialized else { reject("stt_error", "STT not initialized", nil); return }
        if let vocabularyCString = vocabulary.cString(using: .utf8) {
            RN_STT_setUserVocabulary(context, vocabularyCString); resolve(nil)
        } else { reject("vocab_error", "Failed to convert vocabulary to C string", nil) }
    }

    @objc(processAudioFileWithOptions:options:resolver:rejecter:)
    func processAudioFileWithOptions(filePath: String, options: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        NSLog("[AudioInputModule] Swift: processAudioFileWithOptions called with filePath: %@", filePath)
        // ... (existing processAudioFileWithOptions, ensure it uses loadAudioSamplesFromFile if needed)
        guard let context = sttContext, isSttInitialized else { reject("stt_error", "STT not initialized", nil); return }
        let samples: [Float]; do { samples = try loadAudioSamplesFromFile(filePath: filePath) } catch { reject("audio_load_error", error.localizedDescription, error); return }
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
            let baseAddress = bufferPtr.baseAddress; return cactus_stt_process_audio_with_params_c(context, baseAddress, UInt32(samples.count), &nativeParams)
        }
        if success {
            if let transcriptCString = cactus_stt_get_transcription(context) {
                let transcript = String(cString: transcriptCString); cactus_free_string_c(transcriptCString); resolve(transcript)
            } else { resolve("") }
        } else { reject("stt_processing_error", "STT processing failed with options", nil) }
    }

    @objc(processAudioFile:resolver:rejecter:)
    func processAudioFile(_ filePath: String, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        processAudioFileWithOptions(filePath: filePath, options: [:], resolver: resolve, rejecter: reject)
    }

    @objc(releaseSTT:rejecter:)
    func releaseSTT(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // ... (existing releaseSTT, ensure isSttInitialized = false) ...
        print("[AudioInputModule] releaseSTT called")
        if let context = sttContext { RN_STT_free(context); self.sttContext = nil }
        self.isSttInitialized = false; resolve("STT released successfully")
    }

    // MARK: - Streaming STT Methods Implementation
    @objc(startStreamingSTTNative:resolver:rejecter:)
    func startStreamingSTTNative(options: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        NSLog("[AudioInputModule] Swift: startStreamingSTTNative called")
        guard let context = sttContext, isSttInitialized else {
            reject("STT_INIT_ERROR", "STT not initialized.", nil); return
        }
        if isStreamingActiveRN {
            reject("STREAM_ACTIVE_ERROR", "A streaming session is already active.", nil); return
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
            moduleInstance.sendEvent(withName: "onSTTPartialResult", body: String(cString: transcriptCString))
        }

        let cFinalCallback: stt_final_result_callback_c_t = { (transcriptCString, userData) -> Void in
            guard let userData = userData else { return }
            let moduleInstance = Unmanaged<AudioInputModule>.fromOpaque(userData).takeRetainedValue() // Consumes the retain from passRetained

            var resultBody: [String: Any] = [:]
            if let cstr = transcriptCString { resultBody["transcript"] = String(cString: cstr) }
            else { resultBody["error"] = STTError.transcriptionFailed.localizedDescription }

            moduleInstance.sendEvent(withName: "onSTTFinalResult", body: resultBody)
            moduleInstance._stopMicCapture() // Stop mic after final result
            moduleInstance.isStreamingActiveRN = false
            moduleInstance.streamUserSelfData = nil // ARC will release the instance due to takeRetainedValue
        }

        let success = cactus_stt_stream_start_c( context, &nativeParams, cPartialCallback, self.streamUserSelfData, cFinalCallback, self.streamUserSelfData)

        if success {
            do {
                try _setupAndStartMicCapture() // Renamed this for clarity
                self.isStreamingActiveRN = true
                resolve(nil)
            } catch {
                if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
                 reject("AUDIO_ENGINE_ERROR", "Failed to start microphone capture: \(error.localizedDescription)", error)
            }
        } else {
            if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
            reject("STREAM_START_ERROR", "Failed to start STT stream (native call failed)", nil)
        }
    }

    private func _setupAndStartMicCapture() throws {
        // Called from startStreamingSTTNative AFTER native stream is started.
        guard let inputNode = self.audioInputNode else { throw STTError.audioEngineError("Audio input node not available.") }
        if audioEngine.isRunning { audioEngine.stop(); inputNode.removeTap(onBus: 0) } // Stop/reset previous if any

        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Using a commonFormat that is float32 and matches sample rate for simplicity to avoid complex conversion in tap
        // This means mic must provide 16kHz Float32 mono or C++ layer must handle conversion
        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] (buffer, time) in
            guard let self = self, self.isStreamingActiveRN else { return }
            let samples = self.convertPCMBufferToFloatArray(buffer: buffer)
            if !samples.isEmpty {
                self.onAudioData(samples)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        print("[AudioInputModule] Microphone capture started via AVAudioEngine.")
    }


    @objc(feedAudioChunkNative:resolver:rejecter:)
    func feedAudioChunkNative(audioDataBase64: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let context = sttContext, isSttInitialized, isStreamingActiveRN else {
            reject("stt_error", "Stream not active or STT not initialized for feedAudioChunk", nil); return
        }
        guard let audioData = Data(base64Encoded: audioDataBase64) else {
            reject("stt_error", "Invalid base64 audio data for chunk", nil); return
        }

        // This conversion assumes JS sends raw PCM data (e.g., Int16) as base64.
        // The C++ layer expects Float32.
        let samples: [Float] = audioData.withUnsafeBytes { bufferPtr -> [Float] in
            guard let int16Ptr = bufferPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return [] }
            let int16Buffer = UnsafeBufferPointer(start: int16Ptr, count: audioData.count / MemoryLayout<Int16>.size)
            return int16Buffer.map { Float($0) / 32768.0 } // Normalize Int16 to Float range [-1.0, 1.0]
        }

        if samples.isEmpty && !audioData.isEmpty {
             reject("stt_error", "Failed to convert base64 audio data to Float samples", nil); return
        }

        let success = samples.withUnsafeBufferPointer { bufferPointer -> Bool in
            let baseAddress = bufferPointer.baseAddress
            return cactus_stt_stream_feed_audio_c(context, baseAddress, UInt32(samples.count))
        }

        if success { resolve(nil) }
        else { reject("stt_error", "Failed to feed audio chunk (native call failed)", nil) }
    }

    @objc(stopStreamingSTTNative:rejecter:)
    func stopStreamingSTTNative(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        _stopMicCapture() // Stop mic first

        guard let context = sttContext, isSttInitialized else {
            if isStreamingActiveRN { // Stream was active but context lost?
                 if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
                 self.sendEvent(withName: "onSTTFinalResult", body: ["error": STTError.notInitialized.localizedDescription])
            }
            self.isStreamingActiveRN = false // Ensure state is reset
            reject("stt_error", "STT not initialized, cannot stop stream.", nil)
            return
        }

        // If not streaming but stop is called, it might be a cleanup attempt or error.
        if !isStreamingActiveRN {
            print("[AudioInputModule] stopStreamingSTTNative called but not actively streaming.")
            // Clean up user_data if it somehow still exists
            if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
            resolve(nil)
            return
        }

        // Native call to finish the stream. The final callback will be triggered from C.
        let success = cactus_stt_stream_finish_c(context)

        if !success {
            // If native finish fails, the C callback might not be called to clean up user_data.
            if let data = self.streamUserSelfData { Unmanaged.fromOpaque(data).release(); self.streamUserSelfData = nil; }
            self.isStreamingActiveRN = false
            self.sendEvent(withName: "onSTTFinalResult", body: ["error": STTError.streamFinishFailed.localizedDescription])
            reject("stt_error", "Failed to stop STT stream (native call failed)", nil)
        } else {
            // Success: Native call initiated finish. The C callback handles cleanup of streamUserSelfData and isStreamingActiveRN.
            resolve(nil)
        }
    }
}
