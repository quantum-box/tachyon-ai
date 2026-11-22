import AVFoundation

/// Captures the default microphone as 24 kHz mono PCM16 (the Realtime API input format).
final class AudioCapture {
    /// Raw little-endian PCM16 chunks. Called on the audio thread.
    var onChunk: ((Data) -> Void)?
    /// Input level 0...1. Called on the audio thread.
    var onLevel: ((Float) -> Void)?

    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: true)!

    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "マイク入力が見つかりません" }
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.noInput
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
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
        let rms = (sum / Float(count)).squareRoot()
        onLevel?(min(1, rms * 6))
        onChunk?(Data(bytes: samples, count: count * MemoryLayout<Int16>.size))
    }
}
