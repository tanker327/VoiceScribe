import AVFoundation
import Combine

/// Records audio from the default input device and provides WAV data for transcription.
class AudioRecorderService: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var levelTimer: Timer?

    // MARK: - Public API

    /// Start recording to a temp WAV file.
    func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        tempFileURL = fileURL

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // Create output file – 16-bit PCM for maximum compatibility
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Install tap — downsample to 16kHz mono for Whisper
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: recordingFormat, to: desiredFormat)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self, let audioFile = self.audioFile else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (16000.0 / recordingFormat.sampleRate)
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, convertedBuffer.frameLength > 0 {
                try? audioFile.write(from: convertedBuffer)

                // Compute audio level for UI
                let channelData = convertedBuffer.floatChannelData?[0]
                let length = Int(convertedBuffer.frameLength)
                if let data = channelData, length > 0 {
                    var sum: Float = 0
                    for i in 0..<length { sum += abs(data[i]) }
                    let avg = sum / Float(length)
                    DispatchQueue.main.async {
                        self.audioLevel = avg
                    }
                }
            }
        }

        try audioEngine.start()
        isRecording = true
    }

    /// Stop recording and return the WAV file URL.
    func stopRecording() -> URL? {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFile = nil
        isRecording = false
        audioLevel = 0
        return tempFileURL
    }

    /// Clean up temp file.
    func cleanupTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    deinit {
        cleanupTempFile()
    }

    // MARK: - Errors

    enum RecorderError: LocalizedError {
        case noInputDevice
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No audio input device found."
            }
        }
    }
}
