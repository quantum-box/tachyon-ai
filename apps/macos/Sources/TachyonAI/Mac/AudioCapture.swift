import AVFoundation

/// Captures the default microphone as 24 kHz mono PCM16 (the Realtime API input format).
///
/// Uses a capture session rather than `AVAudioEngine`: the engine ties input and output
/// together and delivers silence when the two run at different sample rates, which is
/// what happens with Bluetooth headsets (24 kHz microphone, 48 kHz playback).
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Raw little-endian PCM16 chunks. Called on the capture queue.
    var onChunk: ((Data) -> Void)?
    /// Input level 0...1. Called on the capture queue.
    var onLevel: ((Float) -> Void)?

    static let sampleRate: Double = 24_000

    /// What one recording looked like, for telling "no audio arrived" from "it was silent".
    struct Summary {
        /// The microphone and its own sample rate, e.g. "AirPods Pro 24000Hz".
        var input = "-"
        var buffers = 0
        /// Loudest input level seen, 0...1.
        var peak: Float = 0
        /// The app's microphone input was muted when the recording started.
        var wasMuted = false

        /// Audio arrived, but all of it was digital silence.
        var wasSilent: Bool { buffers > 10 && peak == 0 }
    }

    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "one.tachy.ai.audio-capture")
    /// Starting and stopping a session blocks, so it is kept off the main thread.
    private let controlQueue = DispatchQueue(label: "one.tachy.ai.audio-control")

    /// Guards `summary`, which the capture queue and the main thread share.
    private let lock = NSLock()
    private var summary = Summary()

    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "マイク入力が見つかりません" }
    }

    /// A new session every time, so the microphone that is the default right now is used.
    func start() throws {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw CaptureError.noInput
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // The session converts from whatever the microphone delivers.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureError.noInput
        }
        session.addInput(input)
        session.addOutput(output)

        // Headsets can mute the microphone (on AirPods, a press on the stem), and the
        // muted state outlives the recording it was set in: every later recording is
        // then silent. Holding the dictation key is a clear request to be heard, so
        // this app's own input is unmuted. Other apps keep their own mute state.
        let application = AVAudioApplication.shared
        let wasMuted = application.isInputMuted
        if wasMuted {
            try? application.setInputMuted(false)
        }

        let rate = device.activeFormat.formatDescription.audioStreamBasicDescription?.mSampleRate ?? 0
        lock.withLock {
            summary = Summary()
            summary.wasMuted = wasMuted
            summary.input = "\(device.localizedName.replacingOccurrences(of: " ", with: "_"))_\(Int(rate))Hz"
        }
        self.session = session
        controlQueue.async { session.startRunning() }
    }

    @discardableResult
    func stop() -> Summary {
        if let session {
            controlQueue.async { session.stopRunning() }
        }
        session = nil
        return lock.withLock { summary }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let block = sampleBuffer.dataBuffer, let data = try? block.dataBytes(), !data.isEmpty else { return }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let s = Float(sample) / Float(Int16.max)
                sum += s * s
            }
        }
        let level = min(1, (sum / Float(max(sampleCount, 1))).squareRoot() * 6)
        lock.withLock {
            summary.buffers += 1
            summary.peak = max(summary.peak, level)
        }
        onLevel?(level)
        onChunk?(data)
    }
}
