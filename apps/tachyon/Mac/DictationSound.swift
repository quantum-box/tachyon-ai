import AppKit

/// The two short cues for dictation: a rising pair of notes when recording starts,
/// the same pair falling when the key is released.
///
/// They are synthesized rather than taken from the system sounds, whose tails last
/// half a second or more: the start cue plays while the microphone is already open,
/// so it has to be over before the first word.
enum DictationSound {
    case start
    case end

    func play() {
        guard Preferences.dictationSounds else { return }
        let sound = self == .start ? Self.rising : Self.falling
        sound?.stop()
        sound?.play()
    }

    /// Builds both sounds ahead of the first key press, which would otherwise pay for it.
    static func prepare() {
        _ = (rising, falling)
    }

    private static let rising = tone(notes: [660, 880])
    private static let falling = tone(notes: [880, 660])

    private static let sampleRate = 44_100.0
    private static let noteLength = 0.07
    private static let amplitude = 0.2

    private static func tone(notes: [Double]) -> NSSound? {
        let perNote = Int(sampleRate * noteLength)
        var samples: [Int16] = []
        samples.reserveCapacity(perNote * notes.count)
        for frequency in notes {
            for index in 0..<perNote {
                let time = Double(index) / sampleRate
                // A 4 ms attack and a decay to silence keep each note free of clicks.
                let envelope = min(time / 0.004, 1) * pow(1 - Double(index) / Double(perNote), 2)
                let value = sin(2 * .pi * frequency * time) * envelope * amplitude
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        return NSSound(data: wav(samples))
    }

    /// A 16-bit mono WAV file holding `samples`.
    private static func wav(_ samples: [Int16]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)  // bytes per second
        append(UInt16(2))  // bytes per frame
        append(UInt16(16))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        samples.forEach(append)
        return data
    }
}
