import 'dart:async'; // For StreamSubscription
import 'package:flutter/material.dart';
import '../cactus_service.dart';
import 'package:cactus/cactus.dart'; // For ChatMessage, BenchResult, SttOptions
import 'widgets/message_bubble.dart';
import 'widgets/benchmark_view.dart';
import 'widgets/loading_indicator.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final CactusService _cactusService = CactusService();
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _vocabularyController = TextEditingController(); // For STT Vocabulary
  final ScrollController _scrollController = ScrollController();

  // --- STT Streaming and Advanced Controls State ---
  SttOptions _sttOptions = SttOptions();
  bool _isSttStreaming = false;
  String _partialTranscript = "";
  String _finalTranscriptForStream = "";
  StreamSubscription? _sttStreamSubscription;
  // TODO: Add actual microphone streaming setup
  // StreamSubscription? _micSubscription;
  // AudioInputService _audioInputService = AudioInputService(); // Placeholder for actual audio input

  @override
  void initState() {
    super.initState();
    _cactusService.initialize();
    // Listen to ValueNotifiers to rebuild UI when they change
    _cactusService.chatMessages.addListener(_scrollToBottom);
    _cactusService.transcribedText.addListener(_onTranscribedTextChanged);
    _cactusService.sttError.addListener(_onSttError);
  }

  @override
  void dispose() {
    _sttStreamSubscription?.cancel();
    // TODO: _micSubscription?.cancel();
    if (_isSttStreaming) {
      _stopSttStreaming(propagateError: false).catchError((e) { // Ensure graceful stop
        print("Error stopping stream during dispose: $e");
      });
    }
    _cactusService.chatMessages.removeListener(_scrollToBottom);
    _cactusService.transcribedText.removeListener(_onTranscribedTextChanged);
    _cactusService.sttError.removeListener(_onSttError);
    _vocabularyController.dispose();
    _cactusService.dispose();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // --- UI for STT Controls ---
  Widget _buildSttControlsArea(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView( // Allow scrolling for STT controls if they take too much space
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("STT Controls & Streaming", style: Theme.of(context).textTheme.titleMedium),
            // Vocabulary Input
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _vocabularyController,
                      decoration: const InputDecoration(
                        hintText: 'STT vocabulary (e.g., names)',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      final String vocabulary = _vocabularyController.text.trim();
                      _cactusService.sttService.setUserVocabulary(vocabulary);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(vocabulary.isNotEmpty ? 'STT vocabulary set: $vocabulary' : 'STT vocabulary cleared.')),
                      );
                    },
                    child: const Text('Set Vocab'),
                  ),
                ],
              ),
            ),
            // Advanced STT Options
            SwitchListTile(
              title: const Text('Token Timestamps'),
              value: _sttOptions.tokenTimestamps ?? false,
              onChanged: (bool value) => setState(() => _sttOptions = SttOptions(tokenTimestamps: value, nThreads: _sttOptions.nThreads, temperature: _sttOptions.temperature, speedUp: _sttOptions.speedUp, audioCtx: _sttOptions.audioCtx, maxLen: _sttOptions.maxLen, maxTokens: _sttOptions.maxTokens, noContext: _sttOptions.noContext)),
              dense: true,
            ),
            SwitchListTile(
              title: const Text('No Context (for STT processing calls)'),
              value: _sttOptions.noContext ?? true,
              onChanged: (bool value) => setState(() => _sttOptions = SttOptions(noContext: value, nThreads: _sttOptions.nThreads, tokenTimestamps: _sttOptions.tokenTimestamps, temperature: _sttOptions.temperature, speedUp: _sttOptions.speedUp, audioCtx: _sttOptions.audioCtx, maxLen: _sttOptions.maxLen, maxTokens: _sttOptions.maxTokens)),
              dense: true,
            ),
            // SwitchListTile for Translate - assuming it might be added to SttOptions later or handled differently
            // For now, it's commented out as it's not in the current SttOptions Dart definition.
            // SwitchListTile(
            //   title: const Text('Translate to English (STT)'),
            //   value: _sttOptions.translate ?? false, // Requires translate field in SttOptions
            //   onChanged: (bool value) => setState(() => _sttOptions = SttOptions(translate: value, /* copy other options */ )),
            //   dense: true,
            // ),
            Row(
              children: [
                const Text("STT Temp:"),
                Expanded(
                  child: Slider(
                    value: _sttOptions.temperature ?? 0.0,
                    min: 0.0, max: 1.0, divisions: 20,
                    label: (_sttOptions.temperature ?? 0.0).toStringAsFixed(2),
                    onChanged: (double value) => setState(() => _sttOptions = SttOptions(temperature: value, nThreads: _sttOptions.nThreads, tokenTimestamps: _sttOptions.tokenTimestamps, speedUp: _sttOptions.speedUp, audioCtx: _sttOptions.audioCtx, maxLen: _sttOptions.maxLen, maxTokens: _sttOptions.maxTokens, noContext: _sttOptions.noContext)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: _cactusService.isRecording, // For buffered recording
                  builder: (context, isBufferedRecording, child) {
                    return ElevatedButton.icon(
                      icon: Icon(isBufferedRecording ? Icons.mic_off : Icons.mic),
                      label: Text(isBufferedRecording ? 'Stop Buffered' : 'Record Full'),
                      onPressed: _isSttStreaming ? null : _toggleBufferedRecording,
                      style: ElevatedButton.styleFrom(backgroundColor: isBufferedRecording ? Colors.orangeAccent : Colors.lightBlueAccent),
                    );
                  }
                ),
                ElevatedButton.icon(
                  icon: Icon(_isSttStreaming ? Icons.stop_circle_outlined : Icons.stream),
                  label: Text(_isSttStreaming ? 'Stop Stream' : 'Start Stream'),
                  onPressed: _cactusService.isLoading.value || _cactusService.isRecording.value ? null : (_isSttStreaming ? () => _stopSttStreaming() : _startSttStreaming),
                  style: ElevatedButton.styleFrom(backgroundColor: _isSttStreaming ? Colors.redAccent : Colors.greenAccent),
                ),
              ],
            ),
            if (_isSttStreaming || _partialTranscript.isNotEmpty || _finalTranscriptForStream.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_partialTranscript.isNotEmpty)
                      Text("Partial: $_partialTranscript", style: const TextStyle(color: Colors.grey)),
                    if (_finalTranscriptForStream.isNotEmpty)
                      Text(_finalTranscriptForStream, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ValueListenableBuilder<String?>(
              valueListenable: _cactusService.sttError, // For non-streaming STT error
              builder: (context, error, child) {
                if (error != null && error.isNotEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text("Buffered STT Error: $error", style: const TextStyle(color: Colors.red)),
                  );
                }
                return const SizedBox.shrink();
              }
            ),
          ],
        ),
      ),
    );
  }
  // --- End UI for STT Controls ---

  // --- End UI for STT Controls ---

  // --- STT Streaming Logic ---
  Future<void> _startSttStreaming() async {
    if (_isSttStreaming) return;
    if (!_cactusService.sttService.isInitialized) {
      _showSnackbar('STT Engine not initialized. Please initialize first.');
      return;
    }

    // TODO: Implement actual microphone permission request and stream start here.
    // This involves using a microphone plugin like 'mic_stream' or 'flutter_sound'.
    // Example (conceptual):
    // bool micPermission = await _audioInputService.requestPermissions(); // Assuming _audioInputService handles this
    // if (!micPermission) {
    //   _showSnackbar('Microphone permission denied.');
    //   return;
    // }
    // await _audioInputService.start((audioChunk) => _onAudioData(audioChunk)); // Start mic and pass data to _onAudioData
    _showSnackbar("Mock microphone stream started. Implement real mic input for actual audio data.");


    setState(() {
      _isSttStreaming = true;
      _partialTranscript = "";
      _finalTranscriptForStream = "Streaming...";
    });

    try {
      await _sttStreamSubscription?.cancel();
      _sttStreamSubscription = null;

      final sttStream = await _cactusService.sttService.startStreamingSTT(
        options: _sttOptions,
        onFinalResult: (finalTranscript) {
          if (mounted) {
            setState(() {
              _finalTranscriptForStream = "Final: $finalTranscript";
              _partialTranscript = "";
              _isSttStreaming = false;
            });
          }
          _stopMicStream();
        },
        onStreamError: (error) {
          if (mounted) {
            setState(() {
              _finalTranscriptForStream = "Error: $error";
              _partialTranscript = "";
              _isSttStreaming = false;
            });
          }
          _stopMicStream();
        },
      );

      _sttStreamSubscription = sttStream.listen(
        (partial) {
          if (mounted) {
            setState(() { _partialTranscript = partial; });
          }
        },
        onError: (error, stackTrace) {
          print("STT Stream Error from Dart Stream: $error\n$stackTrace");
          if (mounted) {
            setState(() {
              _finalTranscriptForStream = "Stream Error: $error";
              _partialTranscript = "";
              _isSttStreaming = false;
            });
          }
          _stopMicStream();
        },
        onDone: () {
          if (mounted && _isSttStreaming) {
            print("STT Stream closed (onDone) while still marked as streaming by UI.");
            setState(() { _isSttStreaming = false; });
          }
          _stopMicStream();
        },
        cancelOnError: true,
      );

      print("STT Streaming service connection established. Waiting for audio data...");
      // TODO: Simulate receiving audio data if no mic plugin is integrated for this example
      // For example, a timer that calls _onAudioData with dummy chunks:
      // _simulateMicInput();

    } catch (e) {
      print("Failed to start STT stream: $e");
      if (mounted) {
        setState(() {
          _isSttStreaming = false;
          _finalTranscriptForStream = "Error starting stream: $e";
        });
      }
    }
  }

  void _onAudioData(List<double> audioChunk) {
    if (!_isSttStreaming || !_cactusService.sttService.isInitialized) return;
    _cactusService.sttService.feedAudioChunk(audioChunk).catchError((e) {
      print("Failed to feed audio chunk: $e");
      if (mounted) {
        setState(() {
          _finalTranscriptForStream = "Error feeding audio: $e";
          _isSttStreaming = false;
        });
         _stopMicStream();
      }
    });
  }

  Future<void> _stopSttStreaming({bool propagateError = true}) async {
    if (!_isSttStreaming && _sttStreamSubscription == null) {
      if(mounted) setState(() { _isSttStreaming = false; });
      return;
    }

    _stopMicStream();
    print("Microphone streaming stopped by user call to _stopSttStreaming.");

    try {
      await _cactusService.sttService.stopStreamingSTT();
      print("STT Streaming stop signal sent to service.");
    } catch (e) {
      print("Error stopping STT stream via service: $e");
      if (mounted) {
        setState(() {
          _finalTranscriptForStream = _finalTranscriptForStream.isEmpty ? "Error stopping stream: $e" : _finalTranscriptForStream;
          // _isSttStreaming state is primarily managed by the onFinalResult/onError callbacks from startStreamingSTT
        });
        if(propagateError && _cactusService.sttService.isStreaming) {
           // If the service's stop method itself fails, and callbacks might not fire to update state.
           _cactusService.sttService.handleStreamErrorForFlutter("Error stopping stream: $e"); // Hypothetical
           setState(() { _isSttStreaming = false; });
        }
      }
    } finally {
      await _sttStreamSubscription?.cancel();
      _sttStreamSubscription = null;
       if (mounted && _isSttStreaming) {
          setState(() { _isSttStreaming = false; });
       }
    }
  }

  void _stopMicStream() {
    // TODO: Implement actual microphone stream stop using a plugin
    // For example: await _micSubscription?.cancel(); _micSubscription = null;
    print("MOCK: Microphone stream stopped by _stopMicStream(). Implement actual mic handling.");
  }
  // --- End STT Streaming Logic ---

  void _sendMessage() {
    final userInput = _promptController.text.trim();
    if (userInput.isEmpty && _cactusService.imagePathForNextMessage.value == null) return;

    _cactusService.sendMessage(userInput);
    _promptController.clear();
    _scrollToBottom(); 
  }

  void _scrollToBottom() {
    // Schedule scroll after the frame has been built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _pickAndStageImage() {
    // Using a predefined asset for simplicity in this refactor
    // A real app would use image_picker or similar
    const String assetPath = 'assets/image.jpg'; 
    const String tempFilename = 'temp_chat_image.jpg';
    _cactusService.stageImageFromAsset(assetPath, tempFilename);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cactus Flutter Chat'),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: _cactusService.isBenchmarking,
            builder: (context, isBenchmarking, child) {
              return IconButton(
                icon: const Icon(Icons.memory), // Benchmark icon
                onPressed: isBenchmarking || _cactusService.isLoading.value ? null : () => _cactusService.runBenchmark(),
                tooltip: 'Run Benchmark',
              );
            }
          ),
        ],
      ),
      body: ValueListenableBuilder<String?>(
        valueListenable: _cactusService.initError,
        builder: (context, initError, _) {
          if (initError != null) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Center(
                child: Text(
                  initError,
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          // Use multiple ValueListenableBuilders to react to specific state changes
          return ValueListenableBuilder<bool>(
            valueListenable: _cactusService.isLoading,
            builder: (context, isLoading, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: _cactusService.isBenchmarking,
                builder: (context, isBenchmarking, _) {
                  return ValueListenableBuilder<List<ChatMessage>>(
                    valueListenable: _cactusService.chatMessages,
                    builder: (context, chatMessages, _ ) {
                       // Show initial loading only if no messages and not benchmarking and no error
                        bool showInitialLoading = isLoading && chatMessages.isEmpty && !isBenchmarking && initError == null;

                        return Column(
                        children: [
                          if (showInitialLoading || (isBenchmarking && chatMessages.isEmpty) ) // Show loading or benchmark progress if chat is empty
                            ValueListenableBuilder<double?>(
                              valueListenable: _cactusService.downloadProgress,
                              builder: (context, downloadProgress, _) {
                                return ValueListenableBuilder<String>(
                                  valueListenable: _cactusService.statusMessage,
                                  builder: (context, statusMessage, _) {
                                    return LoadingIndicator(
                                      isLoading: isLoading, 
                                      isBenchmarking: isBenchmarking,
                                      downloadProgress: downloadProgress,
                                      statusMessage: statusMessage,
                                    );
                                  }
                                );
                              }
                            ),
                          ValueListenableBuilder<BenchResult?>(
                            valueListenable: _cactusService.benchResult,
                            builder: (context, benchResult, _) {
                              return BenchmarkView(benchResult: benchResult);
                            }
                          ),
                          Expanded(
                            child: ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(8.0),
                              itemCount: chatMessages.length,
                              itemBuilder: (context, index) {
                                final message = chatMessages[index];
                                return MessageBubble(message: message);
                              },
                            ),
                          ),
                          if (!showInitialLoading) // Hide input if initially loading
                            _buildChatInputArea(context, isLoading),
                        ],
                      );
                    }
                  );
                }
              );
            }
          );
        }
      ),
    );
  }

  Widget _buildChatInputArea(BuildContext context, bool currentIsLoading) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // STT Vocabulary Input Area
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _vocabularyController,
                    decoration: const InputDecoration(
                      hintText: 'Enter STT vocabulary (e.g., names, jargon)',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final String vocabulary = _vocabularyController.text.trim();
                    if (vocabulary.isNotEmpty) {
                      // Assuming CactusService has a method that internally calls sttService.setUserVocabulary
                      // Or directly if sttService is exposed and method is public.
                      // Based on previous finding: `_cactusService.setSttUserVocabulary`
                      // For now, let's assume direct access or a similar method in CactusService
                       _cactusService.sttService.setUserVocabulary(vocabulary);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('STT vocabulary set: $vocabulary')),
                      );
                    } else {
                       _cactusService.sttService.setUserVocabulary(""); // Clear if empty
                       ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('STT vocabulary cleared.')),
                      );
                    }
                  },
                  child: const Text('Set Vocab'),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: _cactusService.stagedAssetPath, // Listen to the staged asset path
            builder: (context, stagedAssetPathValue, _) {
              if (stagedAssetPathValue != null) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      Image.asset( // Display from asset path for consistency
                        stagedAssetPathValue,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                      const SizedBox(width: 8),
                      const Text("Image staged"),
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _cactusService.clearStagedImage(),
                      )
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            }
          ),
          Row(
            children: [
              ValueListenableBuilder<String?>(
                valueListenable: _cactusService.stagedAssetPath,
                builder: (context, stagedAssetPathValue, _) {
                  return IconButton(
                    icon: Icon(Icons.image, color: stagedAssetPathValue != null ? Theme.of(context).primaryColor : null),
                    onPressed: currentIsLoading ? null : () {
                      if (stagedAssetPathValue == null) {
                        _pickAndStageImage();
                      } else {
                        _cactusService.clearStagedImage();
                      }
                    },
                  );
                }
              ),
              Expanded(
                child: TextField(
                  controller: _promptController,
                  decoration: const InputDecoration(
                    hintText: 'Type your message...',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => currentIsLoading ? null : _sendMessage(),
                  minLines: 1,
                  maxLines: 3,
                  enabled: !currentIsLoading,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _cactusService.isLoading, // Specifically listen to overall isLoading for send button
                builder: (context, isLoadingForSendButton, _) {
                  return IconButton(
                    icon: isLoadingForSendButton && !(_cactusService.chatMessages.value.isEmpty && isLoadingForSendButton)
                        ? const SizedBox(width:24, height:24, child:CircularProgressIndicator(strokeWidth: 2,))
                        : const Icon(Icons.send),
                    onPressed: isLoadingForSendButton ? null : _sendMessage,
                  );
                }
              ),
              // Microphone Button
              ValueListenableBuilder<bool>(
                valueListenable: _cactusService.isRecording,
                builder: (context, isRecording, child) {
                  return IconButton(
                    icon: Icon(isRecording ? Icons.mic_off : Icons.mic, color: isRecording ? Colors.red : null),
                    onPressed: currentIsLoading ? null : _toggleRecording,
                    tooltip: isRecording ? 'Stop Recording' : 'Start Recording',
                  );
                }
              ),
            ],
          ),
          // Display STT Error if any
          ValueListenableBuilder<String?>(
            valueListenable: _cactusService.sttError,
            builder: (context, error, child) {
              if (error != null && error.isNotEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(error, style: const TextStyle(color: Colors.red)),
                );
              }
              return const SizedBox.shrink();
            }
          ),
        ],
      ),
    );
  }

  void _onTranscribedTextChanged() {
    final newText = _cactusService.transcribedText.value;
    if (newText != null && newText.isNotEmpty) {
      _promptController.text = newText;
      // Optionally send message directly after transcription:
      // _sendMessage();
      // _cactusService.transcribedText.value = null; // Clear after use
    }
  }

  void _onSttError() {
    final error = _cactusService.sttError.value;
    if (error != null && error.isNotEmpty) {
      // Optionally show a dialog or a more prominent error message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error, style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red)
      );
    }
  }

  Future<void> _toggleRecording() async {
    // Vocabulary is now set via the TextField and Button.
    // The call to _cactusService.sttService.setUserVocabulary() happens when the "Set Vocab" button is pressed.
    // So, no need to call it directly here unless a different flow is desired.

    if (!_cactusService.isRecording.value) {
      bool granted = await _cactusService.requestMicrophonePermissions();
      if (granted) {
        _cactusService.startVoiceCapture();
      } else {
        _cactusService.sttError.value = "Microphone permission denied.";
      }
    } else {
      _cactusService.stopVoiceCapture();
    }
  }
} 