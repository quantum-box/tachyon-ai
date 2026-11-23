import Foundation

/// Development tool: transcribes an audio file through the same path as a dictation,
/// so models and settings can be compared on identical audio.
///
///     TachyonAI --transcribe speech.wav [--gateway] [--model gpt-transcribe]
///         [--keywords "Tachyon Field,Claude Code"] [--prompt "..."] [--verbose]
///
/// Without options the file is transcribed exactly as a dictation is (configured model,
/// vocabulary, background); `--gateway` leaves the session as the gateway issued it,
/// and the other options replace single settings.
/// The file must be 24 kHz mono 16-bit WAV
/// (`afconvert -f WAVE -d LEI16@24000 -c 1 in.aiff out.wav`). It is sent at speaking
/// pace, as a microphone would deliver it.
@MainActor
enum TranscribeEval {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let path = value(of: "--transcribe", in: arguments) else { return false }

        var tuning = arguments.contains("--gateway") ? .none : RealtimeTranscriber.Tuning.dictation()
        if let model = value(of: "--model", in: arguments) { tuning.model = model }
        if let keywords = value(of: "--keywords", in: arguments) {
            tuning.keywords = keywords.split(separator: ",").map(String.init)
        }
        if let prompt = value(of: "--prompt", in: arguments) { tuning.prompt = prompt }
        let verbose = arguments.contains("--verbose")

        Task {
            do {
                try await run(path: path, tuning: tuning, verbose: verbose)
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
        return true
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func run(path: String, tuning: RealtimeTranscriber.Tuning, verbose: Bool) async throws {
        let pcm = try samples(of: Data(contentsOf: URL(fileURLWithPath: path)))
        let auth = AuthService()
        let transcriber = RealtimeTranscriber(loadConfig: { try await auth.config() }, tuning: tuning)
        let started = Date()
        var firstDelta: TimeInterval?
        transcriber.onPartial = { _ in
            if firstDelta == nil { firstDelta = Date().timeIntervalSince(started) }
        }
        transcriber.onRawEvent = { event in
            let isText = event.contains("input_audio_transcription.delta")
            if verbose, !isText { print("< \(event.prefix(1500))") }
        }
        var settled: RealtimeTranscriber.Metrics?
        transcriber.onSettled = { settled = $0 }
        transcriber.start()
        transcriber.beginTurn()

        // 100 ms chunks (24 kHz, 16-bit mono: 4800 bytes), one every 100 ms.
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 4800, pcm.count)
            transcriber.append(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let released = Date()
        let streamed = transcriber.streamedText
        let text = try await transcriber.finish()
        let waited = Date().timeIntervalSince(released)
        while settled == nil { try await Task.sleep(nanoseconds: 50_000_000) }

        print("model=\(settled?.model ?? "-") tuning=\(settled?.tuning ?? "-")"
            + " audio_s=\(String(format: "%.1f", Double(pcm.count) / 48_000))"
            + " first_delta_s=\(firstDelta.map { String(format: "%.2f", $0) } ?? "-")"
            + " streamed_before_release=\(streamed.count)"
            + " after_release_s=\(String(format: "%.2f", waited))"
            // Typing while speaking relies on text, once streamed, not being revised.
            + " final_extends_streamed=\(text.hasPrefix(streamed.trimmingCharacters(in: .whitespaces)))")
        if verbose { print("streamed: \(streamed)") }
        print(text)
    }

    /// The contents of the WAV file's `data` chunk.
    private static func samples(of wav: Data) throws -> Data {
        guard let marker = wav.range(of: Data("data".utf8)), marker.upperBound + 4 <= wav.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return wav.subdata(in: (marker.upperBound + 4)..<wav.count)
    }
}
