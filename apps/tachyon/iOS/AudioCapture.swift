import AVFoundation

/// Captures the microphone as 24 kHz mono PCM16 (the Realtime API input format).
///
/// The iOS counterpart of the Mac app's capture: same interface, built on the audio
/// session and engine, which is how iOS routes microphones (built-in, AirPods, wired).
final class AudioCapture {
    /// Raw little-endian PCM16 chunks. Called on the audio thread.
    var onChunk: ((Data) -> Void)?
    /// Input level 0...1. Called on the audio thread.
    var onLevel: ((Float) -> Void)?

    static let sampleRate: Double = 24_000

    struct Summary {
        var input = "-"
        var buffers = 0
        /// Loudest input level seen, 0...1.
        var peak: Float = 0
        var wasMuted = false

        /// Audio arrived, but all of it was digital silence.
        var wasSilent: Bool { buffers > 10 && peak == 0 }
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: true)!

    /// Guards `converter` and `summary`, which the audio thread and the main thread share.
    private let lock = NSLock()
    private var summary = Summary()

    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "マイク入力が見つかりません" }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Bluetooth is allowed so AirPods' microphone can be used.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }

        lock.withLock {
            summary = Summary()
            summary.input = "\(session.currentRoute.inputs.first?.portName ?? "?")_\(Int(format.sampleRate))Hz"
                .replacingOccurrences(of: " ", with: "_")
            converter = nil
        }
        input.installTap(onBus: 0, bufferSize: 2400, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    @discardableResult
    func stop() -> Summary {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return lock.withLock {
            converter = nil
            return summary
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        let converter = self.converter
        lock.unlock()
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }

        let count = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / Float(Int16.max)
            sum += s * s
        }
        let level = min(1, (sum / Float(count)).squareRoot() * 6)
        lock.withLock {
            summary.buffers += 1
            summary.peak = max(summary.peak, level)
        }
        onLevel?(level)
        onChunk?(Data(bytes: samples, count: count * MemoryLayout<Int16>.size))
    }
}
