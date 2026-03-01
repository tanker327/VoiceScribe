import AVFoundation
import CoreAudio
import Combine

/// Records audio from the default input device and provides WAV data for transcription.
class AudioRecorderService: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    /// Serial queue protecting `audioFile` from concurrent access between
    /// the real-time audio tap callback and `stopRecording()`.
    private let audioFileQueue = DispatchQueue(label: "com.voicescribe.audiofile")

    /// Name of the system default audio input device
    var inputDeviceName: String {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            return "No Input"
        }
        var nameSize: UInt32 = 256
        var cName = [CChar](repeating: 0, count: 256)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &cName)
        return status == noErr ? String(cString: cName) : "Unknown"
    }

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
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw RecorderError.formatNotSupported
        }
        guard let converter = AVAudioConverter(from: recordingFormat, to: desiredFormat) else {
            throw RecorderError.formatNotSupported
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (16000.0 / recordingFormat.sampleRate)
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, convertedBuffer.frameLength > 0 {
                // Write to file on a serial queue to avoid racing with stopRecording()
                self.audioFileQueue.sync {
                    try? self.audioFile?.write(from: convertedBuffer)
                }

                // Compute audio level (RMS) for UI
                let channelData = convertedBuffer.floatChannelData?[0]
                let length = Int(convertedBuffer.frameLength)
                if let data = channelData, length > 0 {
                    var sumOfSquares: Float = 0
                    for i in 0..<length { sumOfSquares += data[i] * data[i] }
                    let rms = sqrtf(sumOfSquares / Float(length))
                    DispatchQueue.main.async {
                        // Smooth the level to avoid jitter
                        self.audioLevel = self.audioLevel * 0.3 + rms * 0.7
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
        // Nil out audioFile on the same serial queue to ensure no in-flight writes
        audioFileQueue.sync {
            audioFile = nil
        }
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
        case formatNotSupported

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device found."
            case .formatNotSupported:
                return "Audio format conversion is not supported for the current input device."
            }
        }
    }
}
