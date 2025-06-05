import UIKit
import AVFoundation
import Cactus // Assumes SttOptions is available via this import

// Helper to get a C-style function pointer for callbacks
// Not strictly needed if using @convention(c) closures directly where FFI function is called
// typealias SttPartialCallbackType = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
// typealias SttFinalCallbackType = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void


class ViewController: UIViewController {

    private var cactusSTTService: CactusSTTService?
    // private var isRecording = false // Replaced by isStreamingActive

    // --- UI Elements ---
    lazy var statusLabel: UILabel = { /* ... */ }()
    lazy var vocabularyTextField: UITextField = { /* ... */ }()
    lazy var setVocabularyButton: UIButton = { /* ... */ }()

    // Renaming recordButton to make its function clear for streaming
    lazy var streamRecordButton: UIButton = { /* ... */ }()

    lazy var transcriptionTextView: UITextView = { /* ... */ }() // For final non-streaming results primarily

    // New UI for STT Options
    lazy var tokenTimestampsSwitch: UISwitch = { self.createSwitch(title: "Token Timestamps") }()
    lazy var noContextSwitch: UISwitch = { self.createSwitch(title: "No Context", isOn: true) }()
    lazy var speedUpSwitch: UISwitch = { self.createSwitch(title: "Speed Up") }()
    lazy var temperatureSlider: UISlider = { self.createSlider(min: 0.0, max: 1.0, initial: 0.0) }()
    lazy var temperatureLabel: UILabel = { self.createLabel(text: "Temp: 0.0") }()

    // New UI for Streaming Transcripts
    lazy var partialTranscriptLabel: UILabel = { self.createLabel(text: "Partial: ", textAlignment: .left) }()
    lazy var finalStreamTranscriptLabel: UILabel = { self.createLabel(text: "Final (Stream): ", textAlignment: .left, weight: .bold) }()

    // Button for processing a dummy buffer with options (simulates "process last recording")
    lazy var processBufferButton: UIButton = { self.createButton(title: "Process Buffer w/ Options") }()

    // --- STT State ---
    var sttOptions = SttOptions() // Initialize with default SttOptions
    var isStreamingActive = false

    // --- Audio Engine for Streaming ---
    let audioEngine = AVAudioEngine()
    var audioInputNode: AVAudioInputNode! // Implicitly unwrapped optional

    // Store self for C callbacks. Must be managed carefully.
    private var streamUserSelfData: UnsafeMutableRawPointer?


    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        title = "iOS STT Example"

        setupUI()
        initializeSTT()
        setupAudioEngine() // Setup audio engine after STT init (or before, if STT doesn't need it at init)

        // Add targets for new UI elements
        tokenTimestampsSwitch.addTarget(self, action: #selector(sttOptionChanged(_:)), for: .valueChanged)
        noContextSwitch.addTarget(self, action: #selector(sttOptionChanged(_:)), for: .valueChanged)
        speedUpSwitch.addTarget(self, action: #selector(sttOptionChanged(_:)), for: .valueChanged)
        temperatureSlider.addTarget(self, action: #selector(sttOptionChanged(_:)), for: .valueChanged)
        processBufferButton.addTarget(self, action: #selector(processDummyBufferTapped), for: .touchUpInside)

    }

    deinit {
        if let context = sttContext { // Use the stored sttContext
            cactusSTTService?.releaseSTT(completion: { error in // Ensure this calls the FFI free correctly
                if let error = error {
                    print("Error releasing STT: \(error.localizedDescription)")
                } else {
                    print("STT resources released.")
                }
            })
        }
        if let userData = streamUserSelfData {
            Unmanaged.fromOpaque(userData).release()
        }
    }

    // MARK: - UI Setup
    private func createLabel(text: String, textAlignment: NSTextAlignment = .center, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = textAlignment
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 14, weight: weight)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func createSwitch(title: String, isOn: Bool = false) -> UISwitch {
        let uiSwitch = UISwitch()
        uiSwitch.isOn = isOn
        // We'll handle actions via addTarget in viewDidLoad
        uiSwitch.translatesAutoresizingMaskIntoConstraints = false
        // For layout purposes, often a Switch is part of a horizontal stack with a UILabel
        return uiSwitch
    }

    private func createSlider(min: Float, max: Float, initial: Float) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = initial
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }

    private func createButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        button.backgroundColor = .systemGray5
        button.setTitleColor(.systemBlue, for: .normal)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }


    private func setupUI() {
        // Initializing UI elements (some were lazy vars, ensure they are configured)
        statusLabel = createLabel(text: "Initialize STT...")
        vocabularyTextField = UITextField()
        vocabularyTextField.placeholder = "Enter STT vocabulary (optional)"
        vocabularyTextField.borderStyle = .roundedRect
        vocabularyTextField.translatesAutoresizingMaskIntoConstraints = false

        setVocabularyButton = createButton(title: "Set Vocabulary")
        setVocabularyButton.addTarget(self, action: #selector(setVocabularyButtonTapped), for: .touchUpInside)

        streamRecordButton = createButton(title: "Start Streaming")
        streamRecordButton.addTarget(self, action: #selector(streamRecordButtonTapped), for: .touchUpInside)
        streamRecordButton.backgroundColor = .systemGreen

        transcriptionTextView = UITextView()
        transcriptionTextView.font = UIFont.systemFont(ofSize: 16)
        transcriptionTextView.isEditable = false
        transcriptionTextView.layer.borderColor = UIColor.lightGray.cgColor
        transcriptionTextView.layer.borderWidth = 1.0
        transcriptionTextView.layer.cornerRadius = 5
        transcriptionTextView.translatesAutoresizingMaskIntoConstraints = false

        partialTranscriptLabel = createLabel(text: "Partial: ", textAlignment: .left)
        finalStreamTranscriptLabel = createLabel(text: "Final (Stream): ", textAlignment: .left, weight: .bold)
        processBufferButton = createButton(title: "Process Buffer w/ Options")


        let tempStack = UIStackView(arrangedSubviews: [temperatureLabel, temperatureSlider])
        tempStack.axis = .horizontal
        tempStack.spacing = 8
        tempStack.translatesAutoresizingMaskIntoConstraints = false

        let optionsStackView = UIStackView(arrangedSubviews: [
            createHorizontalStack([createLabel(text: "Token Timestamps:"), tokenTimestampsSwitch]),
            createHorizontalStack([createLabel(text: "No Context:"), noContextSwitch]),
            createHorizontalStack([createLabel(text: "Speed Up:"), speedUpSwitch]),
            tempStack
        ])
        optionsStackView.axis = .vertical
        optionsStackView.spacing = 8
        optionsStackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)
        view.addSubview(vocabularyTextField)
        view.addSubview(setVocabularyButton)
        view.addSubview(optionsStackView)
        view.addSubview(streamRecordButton)
        view.addSubview(processBufferButton)
        view.addSubview(partialTranscriptLabel)
        view.addSubview(finalStreamTranscriptLabel)
        view.addSubview(transcriptionTextView) // For non-streaming results


        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            vocabularyTextField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            vocabularyTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            vocabularyTextField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            setVocabularyButton.topAnchor.constraint(equalTo: vocabularyTextField.bottomAnchor, constant: 10),
            setVocabularyButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            optionsStackView.topAnchor.constraint(equalTo: setVocabularyButton.bottomAnchor, constant: 10),
            optionsStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            optionsStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            streamRecordButton.topAnchor.constraint(equalTo: optionsStackView.bottomAnchor, constant: 20),
            streamRecordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            streamRecordButton.widthAnchor.constraint(equalToConstant: 200),
            streamRecordButton.heightAnchor.constraint(equalToConstant: 44),

            processBufferButton.topAnchor.constraint(equalTo: streamRecordButton.bottomAnchor, constant: 10),
            processBufferButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            processBufferButton.widthAnchor.constraint(equalToConstant: 250),
            processBufferButton.heightAnchor.constraint(equalToConstant: 44),

            partialTranscriptLabel.topAnchor.constraint(equalTo: processBufferButton.bottomAnchor, constant: 10),
            partialTranscriptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            partialTranscriptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            finalStreamTranscriptLabel.topAnchor.constraint(equalTo: partialTranscriptLabel.bottomAnchor, constant: 5),
            finalStreamTranscriptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            finalStreamTranscriptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            transcriptionTextView.topAnchor.constraint(equalTo: finalStreamTranscriptLabel.bottomAnchor, constant: 10),
            transcriptionTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            transcriptionTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            transcriptionTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    private func createHorizontalStack(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }

    // MARK: - STT Initialization
    private func initializeSTT() {
        cactusSTTService = CactusSTTService()
        guard let modelPath = Bundle.main.path(forResource: "your_stt_model", ofType: "bin") else { // Ensure you have a model file
            statusLabel.text = "Error: STT Model not found. Add to bundle."
            streamRecordButton.isEnabled = false
            processBufferButton.isEnabled = false
            return
        }

        statusLabel.text = "Initializing STT..."
        cactusSTTService?.initSTT(modelPath: modelPath) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.statusLabel.text = "STT Init Error: \(error.localizedDescription)"
                    self.streamRecordButton.isEnabled = false
                    self.processBufferButton.isEnabled = false
                } else {
                    self.statusLabel.text = "STT Initialized. Ready."
                    self.streamRecordButton.isEnabled = true
                    self.processBufferButton.isEnabled = true
                }
            }
        }
    }

    // MARK: - Audio Engine Setup
    private func setupAudioEngine() {
        audioInputNode = audioEngine.inputNode
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
            statusLabel.text = "Audio session setup failed."
        }
    }

    private func installTapAndPrepareEngine() throws {
        let inputFormat = audioInputNode.inputFormat(forBus: 0)
        // Ensure the tap format matches the desired format for Whisper (16kHz, mono, Float32)
        // If not, an AVAudioConverter would be needed. For simplicity, assume input can provide this.
        // Or, configure inputNode's output format if possible.
        // Let's assume a common input format and convert in convertPCMBufferToFloatArray.

        audioInputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self, self.isStreamingActive else { return }
            let samples = self.convertPCMBufferToFloatArray(buffer: buffer)
            if !samples.isEmpty {
                self.onAudioData(samples)
            }
        }
        audioEngine.prepare()
    }

    private func convertPCMBufferToFloatArray(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let pcmFloatChannelData = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var result: [Float] = []
        result.reserveCapacity(frameLength)

        if channelCount > 0 { // Assuming mono, or take first channel
            let channelData = pcmFloatChannelData[0]
            for i in 0..<frameLength {
                result.append(channelData[i])
            }
        }
        return result
    }

    // MARK: - UI Actions
    @objc private func sttOptionChanged(_ sender: UIView) {
        if let uiSwitch = sender as? UISwitch {
            if uiSwitch == tokenTimestampsSwitch {
                sttOptions.tokenTimestamps = uiSwitch.isOn
            } else if uiSwitch == noContextSwitch {
                sttOptions.noContext = uiSwitch.isOn
            } else if uiSwitch == speedUpSwitch {
                sttOptions.speedUp = uiSwitch.isOn
            }
        } else if let slider = sender as? UISlider {
            if slider == temperatureSlider {
                sttOptions.temperature = slider.value
                temperatureLabel.text = String(format: "Temp: %.2f", slider.value)
            }
        }
    }

    @objc private func setVocabularyButtonTapped() {
        guard let sttService = cactusSTTService, sttService.isInitialized else {
            statusLabel.text = "STT not initialized."; return
        }
        let vocabulary = vocabularyTextField.text ?? ""
        sttService.setUserVocabulary(vocabulary: vocabulary) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error { self?.statusLabel.text = "Vocab Error: \(error.localizedDescription)" }
                else { self?.statusLabel.text = "STT vocabulary set: \(vocabulary.isEmpty ? "Cleared" : vocabulary)" }
            }
        }
    }

    @objc private func streamRecordButtonTapped() {
        if isStreamingActive {
            stopSttStream()
        } else {
            startSttStream()
        }
    }

    @objc private func processDummyBufferTapped() {
        guard let sttService = cactusSTTService, sttService.isInitialized else {
            statusLabel.text = "STT not initialized for buffer processing."; return
        }
        // Create a dummy 1-second audio buffer (16000 samples of silence)
        let dummySamples: [Float] = Array(repeating: 0.0, count: 16000)
        statusLabel.text = "Processing dummy buffer with options..."
        transcriptionTextView.text = ""

        sttService.processAudioSamples(samples: dummySamples, options: sttOptions) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let transcript):
                    self?.transcriptionTextView.text = "Buffer Result: \(transcript)"
                    self?.statusLabel.text = "Dummy buffer processed."
                case .failure(let error):
                    self?.transcriptionTextView.text = "Buffer Error: \(error.localizedDescription)"
                    self?.statusLabel.text = "Buffer processing failed."
                }
            }
        }
    }


    // MARK: - STT Streaming Logic
    func startSttStream() {
        guard !isStreamingActive else { return }
        guard let sttService = cactusSTTService, sttService.isInitialized else {
            statusLabel.text = "STT not initialized for streaming."; return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                DispatchQueue.main.async { self.statusLabel.text = "Microphone permission denied."; }
                return
            }

            DispatchQueue.main.async {
                self.isStreamingActive = true
                self.partialTranscriptLabel.text = "Partial: "
                self.finalStreamTranscriptLabel.text = "Final (Stream): Listening..."
                self.streamRecordButton.setTitle("Stop Streaming", for: .normal)
                self.streamRecordButton.backgroundColor = .systemRed
                self.processBufferButton.isEnabled = false // Disable other STT while streaming
            }

            do {
                try self.installTapAndPrepareEngine() // Ensure tap is installed before starting engine
                try self.audioEngine.start()

                try sttService.startStreamingSTT(
                    options: self.sttOptions,
                    onPartialResult: { [weak self] partial in
                        DispatchQueue.main.async { self?.partialTranscriptLabel.text = "Partial: \(partial)" }
                    },
                    onFinalResult: { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            switch result {
                            case .success(let final):
                                self.finalStreamTranscriptLabel.text = "Final (Stream): \(final)"
                            case .failure(let error):
                                self.finalStreamTranscriptLabel.text = "Stream Error: \(error.localizedDescription)"
                            }
                            self.partialTranscriptLabel.text = "Partial: "
                            // Cleanup is handled by stopSttStream or if an error occurs during feed
                            // self.stopSttStream() // Call stop explicitly if not already called
                            if self.isStreamingActive { // Check if stop wasn't already triggered by an error
                                self.stopSttStream(isCalledFromCallback: true)
                            }
                        }
                    }
                )
                print("STT Streaming service started successfully.")
            } catch {
                print("Error starting STT stream or audio engine: \(error)")
                DispatchQueue.main.async {
                    self.isStreamingActive = false
                    self.finalStreamTranscriptLabel.text = "Stream Start Error: \(error.localizedDescription)"
                    self.streamRecordButton.setTitle("Start Streaming", for: .normal)
                    self.streamRecordButton.backgroundColor = .systemGreen
                    self.processBufferButton.isEnabled = true
                    self.audioEngine.stop() // Ensure engine stops if it started
                    self.audioInputNode.removeTap(onBus: 0)
                }
            }
        }
    }

    func onAudioData(_ samples: [Float]) {
        guard isStreamingActive, let sttService = cactusSTTService else { return }
        do {
            try sttService.feedAudioChunk(samples: samples)
        } catch {
            print("Failed to feed audio chunk: \(error)")
            DispatchQueue.main.async {
                self.finalStreamTranscriptLabel.text = "Feed Error: \(error.localizedDescription)"
                self.stopSttStream(isCalledFromCallback: true) // Stop stream on feed error
            }
        }
    }

    func stopSttStream(isCalledFromCallback: Bool = false) {
        if !isCalledFromCallback { // If called by user (button press)
             guard isStreamingActive else { return }
        }
        // If called from callback, isStreamingActive might already be false by the time this executes
        // but we still need to ensure engine and tap are stopped.

        isRecording = false // Legacy flag, ensure it's false

        if audioEngine.isRunning {
            audioEngine.stop()
            audioInputNode.removeTap(onBus: 0)
            print("Microphone streaming stopped.")
        }

        if let sttService = cactusSTTService, self.isStreamingActive { // Check isStreamingActive again before native call
            do {
                try sttService.stopStreamingSTT()
                // Final result is handled by the onFinalResult callback in startStreamingSTT
            } catch {
                print("Error stopping STT stream: \(error)")
                 DispatchQueue.main.async {
                    self.finalStreamTranscriptLabel.text = (self.finalStreamTranscriptLabel.text ?? "").contains("Final") ? self.finalStreamTranscriptLabel.text : "Stop Error: \(error.localizedDescription)"
                }
            }
        }

        // Reset UI and state, unless this was called from a callback that already did it
        if !isCalledFromCallback && mounted { // mounted check for safety
             DispatchQueue.main.async { // Ensure UI updates on main thread
                self.isStreamingActive = false // Ensure this is set
                self.streamRecordButton.setTitle("Start Streaming", for: .normal)
                self.streamRecordButton.backgroundColor = .systemGreen
                self.processBufferButton.isEnabled = true
                if !self.finalStreamTranscriptLabel.text!.contains("Final:") && !self.finalStreamTranscriptLabel.text!.contains("Error:") {
                     self.finalStreamTranscriptLabel.text = "Final (Stream): Stopped."
                }
             }
        } else if isCalledFromCallback && mounted { // If called from callback, ensure button state is reset
             DispatchQueue.main.async {
                self.streamRecordButton.setTitle("Start Streaming", for: .normal)
                self.streamRecordButton.backgroundColor = .systemGreen
                self.processBufferButton.isEnabled = true
             }
        }
    }
}
