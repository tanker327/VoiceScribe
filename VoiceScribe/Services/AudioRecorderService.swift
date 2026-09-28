import AVFoundation
import CoreAudio
import Combine

/// Records audio from the default input device and provides WAV data for transcription.
class AudioRecorderService: ObservableObject {
    /// The audio level changes on every audio buffer. Keeping it in its own observable
    /// means those updates re-render only `AudioLevelBar`, not every view observing the recorder.
    final class LevelMeter: ObservableObject {
        @Published var level: Float = 0.0
    }

    @Published var isRecording = false
    @Published private(set) var inputDeviceName: String = "No Input"
    let levelMeter = LevelMeter()

    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    /// Serial queue protecting `audioFile` from concurrent access between
    /// the real-time audio tap callback and `stopRecording()`.
    private let audioFileQueue = DispatchQueue(label: "com.voicescribe.audiofile")

    init() {
        refreshInputDeviceName()
        installDeviceChangeListener()
    }

    // MARK: - Input Device

    private func refreshInputDeviceName() {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            inputDeviceName = "No Input"
            return
        }
        var nameSize: UInt32 = 256
        var cName = [CChar](repeating: 0, count: 256)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &cName)
        inputDeviceName = status == noErr ? String(cString: cName) : "Unknown"
    }

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshInputDeviceName() }
        }
        deviceChangeListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    // MARK: - Public API

    /// Start recording to a temp WAV file.
    func startRecording() throws {
        guard !isRecording else {
            print("[Recorder] Already recording, ignoring startRecording()")
            return
        }

        // Drop any temp file left behind by a previous attempt that failed part-way.
        cleanupTempFile()

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        tempFileURL = fileURL

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // Create output file - 16-bit PCM for maximum compatibility
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

        // Install tap - downsample to 16kHz mono for Whisper
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw RecorderError.formatNotSupported
        }
        guard let converter = AVAudioConverter(from: recordingFormat, to: desiredFormat) else {
            throw RecorderError.formatNotSupported
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self,
                  let convertedBuffer = Self.downsample(buffer, with: converter, to: desiredFormat) else { return }

            // Write to file on a serial queue (async to avoid blocking the audio thread)
            self.audioFileQueue.async {
                do {
                    try self.audioFile?.write(from: convertedBuffer)
                } catch {
                    print("[Recorder] Failed to write audio buffer: \(error.localizedDescription)")
                }
            }

            // Audio level (RMS) for the meter
            let rms = Self.rms(of: convertedBuffer)
            let meter = self.levelMeter
            DispatchQueue.main.async {
                // Smooth the level to avoid jitter
                meter.level = meter.level * 0.3 + rms * 0.7
            }
        }

        do {
            try audioEngine.start()
        } catch {
            // Leave no tap or open file behind: a second installTap(onBus: 0) on the next
            // attempt would make AVAudioEngine trap.
            inputNode.removeTap(onBus: 0)
            audioFileQueue.sync { audioFile = nil }
            cleanupTempFile()
            throw error
        }
        isRecording = true
        print("[Recorder] Started recording to \(fileURL.lastPathComponent)")
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
        levelMeter.level = 0
        print("[Recorder] Stopped recording")
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
        // Remove device change listener
        if let block = deviceChangeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
        cleanupTempFile()
    }

    // MARK: - Conversion

    /// Converts one tap buffer to the 16 kHz mono recording format.
    /// Internal (not private) so the unit tests can exercise it without a live input device.
    nonisolated static func downsample(_ buffer: AVAudioPCMBuffer,
                                       with converter: AVAudioConverter,
                                       to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard frameCount > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }

        // Hand the input buffer over exactly once. When resampling, the converter may ask
        // for more input to fill the output buffer; answering with the same frames again
        // would write duplicated audio into the WAV.
        var delivered = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0 else { return nil }
        return converted
    }

    /// Root-mean-square level of the first channel; 0 for an empty buffer.
    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let length = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for i in 0..<length { sumOfSquares += data[i] * data[i] }
        return sqrtf(sumOfSquares / Float(length))
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
