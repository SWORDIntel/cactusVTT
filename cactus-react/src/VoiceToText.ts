import { NativeModules, EmitterSubscription, NativeEventEmitter, Platform } from 'react-native';
import type { SttOptions } from './index'; // Import SttOptions

const LINKING_ERROR =
  `The package 'cactus-react-native' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

// Define the interface for the AudioInputModule (iOS)
// These interfaces might need to be expanded based on what methods are actually on the native side
// for STT options and streaming.
interface AudioInputModuleIOS {
  requestPermissions(): Promise<boolean>;
  startRecording(): Promise<string>;
  stopRecording(): Promise<{ filePath: string; fileSize: number }>;
  initSTT(modelPath: string, language?: string): Promise<void>; // Added language
  processAudioFile(filePath: string): Promise<string>;
  processAudioFileWithOptions?(filePath: string, options: SttOptions): Promise<string>; // Optional new method
  releaseSTT(): Promise<void>;
  setUserVocabulary?(vocabulary: string): Promise<void>; // Optional from previous tasks
  // Streaming methods for iOS (if they are on AudioInputModule)
  startStreamingSTTNative?(options: SttOptions): Promise<void>;
  feedAudioChunkNative?(audioChunkBase64: string): Promise<void>;
  stopStreamingSTTNative?(): Promise<void>;
}

// Define the interface for the CactusModule (Android)
interface CactusModuleAndroid {
  initSTT(modelPath: string, language?: string): Promise<void>; // Added language
  processAudioFile(filePath: string): Promise<string>;
  processAudioFileWithOptions?(filePath: string, options: SttOptions): Promise<string>; // Optional new method
  releaseSTT(): Promise<void>;
  setUserVocabulary?(vocabulary: string): Promise<void>; // Optional from previous tasks
  // Streaming methods for Android (expected on CactusModule)
  startStreamingSTTNative?(options: SttOptions): Promise<void>;
  feedAudioChunkNative?(audioChunkBase64: string): Promise<void>;
  stopStreamingSTTNative?(): Promise<void>;

  // Placeholders for existing audio recording methods if they were part of this module
  requestPermissions?(): Promise<boolean>;
  startRecording?(): Promise<string>;
  stopRecording?(): Promise<{ filePath: string; fileSize: number }>;
}

const AudioInputModule: AudioInputModuleIOS = NativeModules.AudioInputModule
  ? NativeModules.AudioInputModule
  : new Proxy(
      {},
      { get() { throw new Error(Platform.OS === 'ios' ? LINKING_ERROR : 'AudioInputModule is not available on Android.'); } }
    );

const ActualCactusModule: CactusModuleAndroid = NativeModules.CactusModule
  ? NativeModules.CactusModule
  : new Proxy(
      {},
      { get() { throw new Error(Platform.OS === 'android' ? LINKING_ERROR : 'CactusModule is not available on iOS.'); } }
    );

// For STT, prefer CactusModule if it exists and has the methods, otherwise fallback to AudioInputModule for iOS.
const STTNativeModule = Platform.select({
    ios: (NativeModules.AudioInputModule?.initSTT ? AudioInputModule : ActualCactusModule) as any, // Prefer AudioInputModule for iOS if it has STT
    android: ActualCactusModule as any,
}) || new Proxy({}, { get() { throw new Error("Appropriate STT native module not found."); } });


export type VoiceToTextEventHandler = (event: any) => void;

export class VoiceToText {
  private nativeAudioModule: AudioInputModuleIOS | CactusModuleAndroid; // For basic recording via AudioInputModule(iOS) or CactusModule(Android, if it has them)
  private sttEventEmitter: NativeEventEmitter; // For STT specific events, from STTNativeModule

  private onAudioDataSubscription?: EmitterSubscription; // For non-STT audio data from recording
  private onErrorSubscription?: EmitterSubscription;     // For non-STT general errors

  // New streaming listeners
  private partialResultSubscription?: EmitterSubscription;
  private finalResultSubscription?: EmitterSubscription;
  private streamErrorSubscription?: EmitterSubscription;

  // User-provided callbacks for streaming
  private _onPartialResult?: (transcript: string) => void;
  private _onFinalResult?: (result: { transcript?: string; error?: string }) => void;
  private _onStreamError?: (error: any) => void;

  modelPath: string | null = null;
  private isRecording: boolean = false;
  private currentTranscription: string | null = null;
  public isStreaming: boolean = false;


  constructor() {
    if (Platform.OS === 'ios') {
      this.nativeAudioModule = AudioInputModule;
    } else if (Platform.OS === 'android') {
      this.nativeAudioModule = ActualCactusModule;
    } else {
      throw new Error('Unsupported platform for nativeAudioModule');
    }
    // Use STTNativeModule for STT events
    this.sttEventEmitter = new NativeEventEmitter(STTNativeModule as any); // Cast needed as NativeEventEmitter expects NativeModule type
    this.setupExistingListeners();
  }

  private setupExistingListeners() {
    // These listeners are for the original audio recording flow (e.g., after stop(); )
    // and general errors from the module that handles audio recording itself.
    const eventSourceForRecording = Platform.OS === 'ios' ? NativeModules.AudioInputModule : NativeModules.CactusModule;
    if (eventSourceForRecording) {
        const recordingEventEmitter = new NativeEventEmitter(eventSourceForRecording);
        this.onAudioDataSubscription = recordingEventEmitter.addListener('onAudioData', (data: { filePath: string }) => {
          console.log('VoiceToText: onAudioData (from recording stop):', data);
          if (this.modelPath && data.filePath) {
            this.processAudio(data.filePath)
              .catch(error => {
                console.error('VoiceToText: Error auto-processing recorded audio file:', error);
                this.sttEventEmitter.emit('onSTTStreamError', { message: 'Error auto-processing audio', details: error });
              });
          }
        });

        this.onErrorSubscription = recordingEventEmitter.addListener('onError', (error: any) => {
          console.error('VoiceToText: Native module error (general recording):', error);
          this._onStreamError?.(error);
        });
    }
  }

  private removeAllStreamListeners() {
    this.partialResultSubscription?.remove();
    this.finalResultSubscription?.remove();
    this.streamErrorSubscription?.remove();
    this.partialResultSubscription = null;
    this.finalResultSubscription = null;
    this.streamErrorSubscription = null;
  }

  async requestPermissions(): Promise<boolean> {
    if (this.nativeAudioModule.requestPermissions) {
        return this.nativeAudioModule.requestPermissions();
    }
    console.warn('requestPermissions not implemented for the current nativeAudioModule.');
    return false;
  }

  async start(): Promise<string> {
    if (this.isRecording) {
      console.warn('Recording is already in progress.');
      return "Already recording";
    }
    if (!this.modelPath) {
        throw new Error('STT model not initialized. Call initSTT(modelPath) first.');
    }
    if (this.nativeAudioModule.startRecording) {
        const result = await this.nativeAudioModule.startRecording();
        this.isRecording = true;
        return result;
    }
    throw new Error('startRecording not implemented for this platform on nativeAudioModule.');
  }

  async stop(): Promise<{ filePath: string; fileSize: number } | null> {
    if (!this.isRecording) {
      console.warn('No recording in progress to stop.');
      return null;
    }
     if (this.nativeAudioModule.stopRecording) {
        const result = await this.nativeAudioModule.stopRecording();
        this.isRecording = false;
        return result;
    }
    throw new Error('stopRecording not implemented for this platform on nativeAudioModule.');
  }

  async initSTT(modelPath: string, language: string = "en"): Promise<void> {
    this.modelPath = modelPath;
    // STT operations should go through STTNativeModule
    if (!STTNativeModule || !STTNativeModule.initSTT) {
        throw new Error("STT native module or initSTT method not available.");
    }
    return STTNativeModule.initSTT(modelPath, language);
  }

  async processAudio(audioPath: string, options?: SttOptions): Promise<string> {
    if (!this.modelPath) {
        throw new Error('STT model not initialized. Call initSTT(modelPath) first.');
    }
    if (!STTNativeModule) {
        throw new Error("STT native module not available.");
    }

    let transcription;
    if (options && STTNativeModule.processAudioFileWithOptions) {
        transcription = await STTNativeModule.processAudioFileWithOptions(audioPath, options);
    } else if (options && STTNativeModule.processAudioFile) {
        console.warn("VoiceToText: SttOptions provided to processAudio but native method 'processAudioFileWithOptions' not found. Options ignored.");
        transcription = await STTNativeModule.processAudioFile(audioPath);
    } else if (STTNativeModule.processAudioFile) {
        transcription = await STTNativeModule.processAudioFile(audioPath);
    } else {
        throw new Error("Suitable processAudioFile or processAudioFileWithOptions method not found on STTNativeModule.");
    }

    this.currentTranscription = transcription;
    this.sttEventEmitter.emit('onTranscription', { transcription });
    return transcription;
  }

  getTranscription(): string | null {
    return this.currentTranscription;
  }

  async releaseSTT(): Promise<void> {
    if (this.modelPath && STTNativeModule && STTNativeModule.releaseSTT) {
      await STTNativeModule.releaseSTT();
      this.modelPath = null;
      this.currentTranscription = null;
    }
  }

  public cleanup(): void {
    this.removeAllStreamListeners();
    this.onAudioDataSubscription?.remove();
    this.onErrorSubscription?.remove();
    this.releaseSTT().catch(error => console.error("VoiceToText: Error releasing STT resources during cleanup:", error));
    console.log('VoiceToText module resources cleaned up.');
  }

  async setUserVocabulary(vocabulary: string): Promise<void> {
    if (!this.modelPath) {
      throw new Error('STT model not initialized. Call initSTT(modelPath) first.');
    }
    if (!STTNativeModule || !STTNativeModule.setUserVocabulary) {
      throw new Error("setUserVocabulary not implemented in the native STT module.");
    }
    if (Platform.OS === 'android') {
        console.warn("VoiceToText: setUserVocabulary on Android might be affected by pending Java module integration.");
    }
    return STTNativeModule.setUserVocabulary(vocabulary);
  }

  // --- Streaming Methods ---

  async startStreamingSTT(
    options?: SttOptions,
    onPartialResult?: (transcript: string) => void,
    onFinalResult?: (result: { transcript?: string; error?: string }) => void,
    onStreamError?: (error: any) => void,
  ): Promise<void> {
    if (!STTNativeModule || !STTNativeModule.startStreamingSTTNative || !this.sttEventEmitter) {
        const message = "STT native module or streaming methods not available.";
        console.error(`VoiceToText: ${message}`);
        onStreamError?.(new Error(message));
        return Promise.reject(new Error(message));
    }
     if (this.isStreaming) {
      throw new Error("VoiceToText: Another stream is already active.");
    }
    if (Platform.OS === 'android') {
        console.warn("VoiceToText: STT streaming on Android might be affected by pending Java module integration.");
    }

    this._onPartialResult = onPartialResult;
    this._onFinalResult = onFinalResult;
    this._onStreamError = onStreamError;

    this.removeAllStreamListeners();

    if (this._onPartialResult) {
        this.partialResultSubscription = this.sttEventEmitter.addListener(
            'onSTTPartialResult',
            this._onPartialResult
        );
    }

    this.finalResultSubscription = this.sttEventEmitter.addListener(
        'onSTTFinalResult',
        (result: { transcript?: string; error?: any }) => {
            if (result.error) {
                this._onStreamError?.(result.error);
            } else {
                this._onFinalResult?.(result);
            }
            this.isStreaming = false; // Mark stream as ended
            this.removeAllStreamListeners();
        }
    );

    // It's good practice to also have a generic error listener for the stream if native side emits one
    this.streamErrorSubscription = this.sttEventEmitter.addListener(
        'onSTTStreamError', // A dedicated error event for the stream
        (error: any) => {
            this._onStreamError?.(error);
            this.isStreaming = false; // Mark stream as ended on error
            this.removeAllStreamListeners();
        }
    );

    try {
      await STTNativeModule.startStreamingSTTNative(options || {});
      this.isStreaming = true;
    } catch (e) {
      this.removeAllStreamListeners(); // Clean up if start itself fails
      this._onStreamError?.(e);
      throw e;
    }
  }

  async feedAudioChunk(audioChunkBase64: string): Promise<void> {
    if (!this.isStreaming) {
      return Promise.reject("Stream not active. Call startStreamingSTT first.");
    }
    if (!STTNativeModule || !STTNativeModule.feedAudioChunkNative) {
        return Promise.reject("feedAudioChunkNative not available on STTNativeModule.");
    }
    if (Platform.OS === 'android') {
        // console.warn("STT streaming feedAudioChunk may not be fully functional on Android.");
    }
    return STTNativeModule.feedAudioChunkNative(audioChunkBase64);
  }

  async stopStreamingSTT(): Promise<void> {
    if (!this.isStreaming && STTNativeModule && STTNativeModule.stopStreamingSTTNative) {
      // If not streaming but method exists, perhaps a state mismatch, try to call stop anyway.
      // Or, if you want to be strict: return Promise.reject("Stream not active.");
      console.warn("VoiceToText: stopStreamingSTT called while not actively streaming, attempting native stop.");
    } else if (!STTNativeModule || !STTNativeModule.stopStreamingSTTNative) {
        this.removeAllStreamListeners();
        return Promise.reject("stopStreamingSTTNative not available on STTNativeModule.");
    }
     if (Platform.OS === 'android') {
        // console.warn("STT streaming stopStreamingSTT may not be fully functional on Android.");
    }
    // The native side should ensure onSTTFinalResult (with data or error) is emitted.
    // Listeners are removed by the onSTTFinalResult/onSTTStreamError handler.
    // We expect stopStreamingSTTNative to trigger one of those events.
    try {
        await STTNativeModule.stopStreamingSTTNative();
    } catch (e) {
        this._onStreamError?.(e);
        this.isStreaming = false; // Ensure state is updated
        this.removeAllStreamListeners();
        throw e;
    }
    // Do not set isStreaming = false here directly; let the final callback handle it.
  }
}
