import React, { useState, useEffect, useCallback } from 'react';
import {
  SafeAreaView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
  PermissionsAndroid,
  Platform,
  TextInput,
  ScrollView,
  Switch,
  ActivityIndicator,
  Alert,
} from 'react-native';
import { VoiceToText, SttOptions } from 'cactus-react';

// It's good practice to define a specific path for your model
// For example, if bundled in android assets or iOS bundle.
// This path is a placeholder and needs to be replaced with your actual model path.
const DEFAULT_MODEL_PATH = Platform.OS === 'ios' ? 'models/your_stt_model.bin' : 'models/your_stt_model.bin';
// Ensure this model is bundled with your app or downloaded to a location
// accessible by the native code. For Android, if using assets, the native code
// part of cactus-react (specifically CactusModule.java/jni.cpp) would need to handle
// asset extraction to a file path before passing to the C++ core.

const App = () => {
  const [voiceToText] = useState(() => new VoiceToText());

  // STT State
  const [isSttInitialized, setIsSttInitialized] = useState(false);
  const [sttModelPath, setSttModelPath] = useState<string>(DEFAULT_MODEL_PATH); // User can change this if needed

  const [isRecording, setIsRecording] = useState(false); // For original buffered recording
  const [isStreaming, setIsStreaming] = useState(false);

  const [transcribedText, setTranscribedText] = useState(''); // For buffered result
  const [partialTranscript, setPartialTranscript] = useState('');
  const [finalTranscript, setFinalTranscript] = useState('');

  const [accentVocabulary, setAccentVocabulary] = useState('');
  const [sttOptions, setSttOptions] = useState<SttOptions>({
    language: 'en',
    translate: false,
    temperature: 0.0,
    noContext: true, // Default to true for isolated calls
    tokenTimestamps: false,
  });

  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    // Cleanup on unmount
    return () => {
      voiceToText.cleanup();
    };
  }, [voiceToText]);

  const handleInitSTT = async () => {
    if (!sttModelPath) {
      setError("Model path is not set.");
      return;
    }
    setIsLoading(true);
    setError('');
    try {
      // Assuming initSTT in VoiceToText takes modelPath and language directly
      // The SttOptions.language will be used for processing calls, not necessarily initial init
      // unless the initSTT method itself is designed to take all these options.
      // For this example, initSTT takes model path, and language option from sttOptions is used for processing.
      // If initSTT itself needs the language, VoiceToText.ts's initSTT should be adapted.
      // Let's assume VoiceToText.initSTT takes modelPath only, and language is set via options later.
      await voiceToText.initSTT(sttModelPath); // Language is part of SttOptions for processing
      setIsSttInitialized(true);
      Alert.alert("Success", `STT Initialized with model: ${sttModelPath}. Language for processing: ${sttOptions.language || 'en'}`);
    } catch (e: any) {
      setError(e.message || 'Failed to initialize STT');
      setIsSttInitialized(false);
    } finally {
      setIsLoading(false);
    }
  };

  const handleSetAccentVocabulary = async () => {
    if (!isSttInitialized) {
      setError("STT not initialized. Cannot set vocabulary.");
      return;
    }
    if (Platform.OS === 'android') {
      console.warn("setUserVocabulary may have limitations on Android due to native module setup.");
      Alert.alert("Android Note", "setUserVocabulary may have limitations on Android due to native module setup.");
    }
    setError('');
    try {
      await voiceToText.setUserVocabulary(accentVocabulary);
      Alert.alert("Success", "Accent Vocabulary Set!");
    } catch (e: any) { setError(e.message || 'Failed to set accent vocabulary'); }
  };

  const handleProcessFileWithOptionsMenu = async () => {
    if (!isSttInitialized) {
      setError("STT not initialized. Cannot process file.");
      return;
    }
    // This is a placeholder for file selection logic
    const dummyFilePath = "path/to/dummy/audiofile.wav"; // Replace with actual file selection
    Alert.alert("Process File", `This would process '${dummyFilePath}' with current SttOptions. Implement actual file picking and processing.`);

    // Example call structure (uncomment and adapt when file path is real):
    // setIsLoading(true);
    // setError('');
    // try {
    //   const result = await voiceToText.processAudio(dummyFilePath, sttOptions);
    //   setTranscribedText(result); // Show in the non-streaming text input
    //   Alert.alert("Processing Complete", "File processed with options.");
    // } catch (e:any) {
    //   setError(e.message || "Failed to process file with options.");
    // } finally {
    //   setIsLoading(false);
    // }
  };

  const handleToggleStreaming = async () => {
    if (Platform.OS === 'android') {
      setError("Streaming STT is not fully supported on Android in this example due to native module setup.");
      Alert.alert("Android Note", "Streaming STT is not fully supported on Android in this example due to native module setup.");
      return;
    }
    if (!isSttInitialized) {
      setError("STT not initialized. Cannot start streaming.");
      return;
    }

    if (isStreaming) {
      setIsLoading(true);
      try {
        await voiceToText.stopStreamingSTT();
        // isStreaming state will be set to false by onFinal or onError callbacks from startStreamingSTT
        // but we set it here to update UI immediately for button state.
        // The final callback will also set it ensuring consistency.
        // No, let the callback handle it to avoid race conditions on transcript display.
        // setIsStreaming(false);
        console.log("Stop streaming signal sent.");
      } catch (e: any) {
        setError(e.message || 'Failed to stop stream');
        setIsStreaming(false); // Force stop on error
      } finally {
        setIsLoading(false);
      }
    } else {
      setPartialTranscript('');
      setFinalTranscript('');
      setError('');
      setIsLoading(true);
      try {
        await voiceToText.startStreamingSTT(
          sttOptions,
          (partial) => {
            // Append partial results for a continuous transcript feel
            setPartialTranscript(prev => prev + partial);
          },
          (result) => { // This is onFinalResult
            if (result.error) {
              setError(result.error);
            } else if (result.transcript !== undefined) {
              setFinalTranscript(result.transcript);
            }
            setIsStreaming(false);
            setIsLoading(false);
            setPartialTranscript(''); // Clear partial on final
          },
          (err) => { // This is onStreamError
             setError(err.message || JSON.stringify(err) || 'Streaming Error');
             setIsStreaming(false);
             setIsLoading(false);
             setPartialTranscript('');
          }
        );
        setIsStreaming(true);
      } catch (e: any) {
        setError(e.message || 'Failed to start stream');
        setIsStreaming(false);
      } finally {
        setIsLoading(false);
      }
    }
  };

  const renderSttOptions = () => (
    <View style={styles.optionsContainer}>
      <Text style={styles.subtitle}>STT Options</Text>
      <View style={styles.optionRow}>
        <Text style={styles.optionLabel}>Language:</Text>
        <TextInput
          style={styles.optionInput}
          value={sttOptions.language}
          onChangeText={lang => setSttOptions(prev => ({...prev, language: lang || undefined}))}
          placeholder="e.g., en, da"
        />
      </View>
      <Button title="Initialize STT Engine" onPress={handleInitSTT} disabled={isLoading || !sttModelPath} />

      <View style={styles.optionRow}>
        <Text style={styles.optionLabel}>Translate to English:</Text>
        <Switch
          value={sttOptions.translate || false}
          onValueChange={val => setSttOptions(prev => ({...prev, translate: val}))}
        />
      </View>
      <View style={styles.optionRow}>
        <Text style={styles.optionLabel}>Token Timestamps:</Text>
        <Switch
          value={sttOptions.tokenTimestamps || false}
          onValueChange={val => setSttOptions(prev => ({...prev, tokenTimestamps: val}))}
        />
      </View>
      <View style={styles.optionRow}>
        <Text style={styles.optionLabel}>No Context:</Text>
        <Switch
          value={sttOptions.noContext || false} // Default for isolated calls is often true
          onValueChange={val => setSttOptions(prev => ({...prev, noContext: val}))}
        />
      </View>
      <View style={styles.optionRow}>
        <Text style={styles.optionLabel}>Temperature: {sttOptions.temperature?.toFixed(2) ?? '0.00'}</Text>
      </View>
      <Slider
          minimumValue={0.0}
          maximumValue={1.0}
          step={0.05}
          value={sttOptions.temperature || 0.0}
          onValueChange={val => setSttOptions(prev => ({...prev, temperature: val}))}
        />
      <TextInput
        style={styles.vocabularyInput}
        value={accentVocabulary}
        onChangeText={setAccentVocabulary}
        placeholder="Accent-specific vocabulary (English phrases)"
      />
      <Button title="Set Accent Vocabulary" onPress={handleSetAccentVocabulary} disabled={isLoading || !isSttInitialized} />
    </View>
  );

  return (
    <SafeAreaView style={styles.safeArea}>
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.title}>Cactus React Native STT Demo</Text>

        {isLoading && <ActivityIndicator size="large" color="#0000ff" />}
        {error ? <Text style={styles.errorText}>{error}</Text> : null}

        {renderSttOptions()}

        <View style={styles.buttonsContainer}>
          <TouchableOpacity
            style={[styles.button, isStreaming ? styles.buttonStreaming : styles.buttonNotStreaming]}
            onPress={handleToggleStreaming}
            disabled={isLoading || !isSttInitialized}
          >
            <Text style={styles.buttonText}>
              {isStreaming ? 'Stop Streaming' : 'Start Streaming'}
            </Text>
          </TouchableOpacity>
          <Button title="Process File w/ Options" onPress={handleProcessFileWithOptionsMenu} disabled={isLoading || !isSttInitialized} />
        </View>

        <Text style={styles.label}>Partial Transcript (Streaming):</Text>
        <Text style={styles.transcriptText}>{partialTranscript}</Text>

        <Text style={styles.label}>Final Transcript (Streaming):</Text>
        <Text style={[styles.transcriptText, styles.boldText]}>{finalTranscript}</Text>

        <Text style={styles.label}>Transcription (File/Buffered):</Text>
        <TextInput
          style={styles.textInput}
          value={transcribedText}
          onChangeText={setTranscribedText} // Allow editing if needed, or set editable={false}
          placeholder="Transcribed text from file/buffered recording..."
          multiline
        />
      </ScrollView>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#f0f0f0' },
  container: {
    padding: 20,
  },
  title: {
    fontSize: 22,
    fontWeight: 'bold',
    marginBottom: 20,
    textAlign: 'center',
  },
  subtitle: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 10,
  },
  optionsContainer: {
    marginBottom: 20,
    padding: 10,
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 5,
  },
  optionRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 10,
  },
  optionLabel: {
    fontSize: 16,
  },
  optionInput: {
    flex: 1,
    marginLeft: 10,
    borderColor: 'gray',
    borderWidth: 1,
    padding: 5,
    borderRadius: 3,
  },
  vocabularyInput: {
    width: '100%',
    height: 40,
    borderColor: '#ced4da',
    borderWidth: 1,
    borderRadius: 5,
    paddingHorizontal: 10,
    backgroundColor: 'white',
    marginBottom: 10,
  },
  buttonsContainer: {
    marginVertical: 10,
  },
  button: {
    paddingVertical: 12,
    paddingHorizontal: 25,
    borderRadius: 8,
    marginBottom: 10,
    alignItems: 'center',
  },
  buttonStreaming: {
    backgroundColor: '#e74c3c',
  },
  buttonNotStreaming: {
    backgroundColor: '#2ecc71',
  },
  buttonText: {
    color: 'white',
    fontSize: 16,
    fontWeight: '500',
  },
  label: {
    fontSize: 16,
    fontWeight: '500',
    marginTop: 15,
    marginBottom: 5,
  },
  transcriptText: {
    fontSize: 14,
    color: '#333',
    marginBottom: 5,
    padding: 5,
    backgroundColor: '#fff',
    borderRadius: 3,
    minHeight: 30,
  },
  boldText: {
    fontWeight: 'bold',
  },
  textInput: { // For non-streaming transcription display
    width: '100%',
    minHeight: 80,
    borderColor: '#bdc3c7',
    borderWidth: 1,
    borderRadius: 5,
    padding: 10,
    backgroundColor: 'white',
    textAlignVertical: 'top',
    marginBottom: 10,
  },
  errorText: {
    color: '#c0392b',
    marginTop: 10,
    textAlign: 'center',
    fontWeight: 'bold',
  },
});

export default App;
