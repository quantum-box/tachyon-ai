import Foundation

/// How long the last dictation took between releasing fn and pasting.
@MainActor
final class DictationStats: ObservableObject {
    static let shared = DictationStats()

    struct Timing {
        /// From releasing the key to the final transcript.
        var transcription: TimeInterval
        /// The tidy-up request; nil when it did not run.
        var cleanup: TimeInterval?
    }

    @Published var last: Timing?

    /// Appends one line of timings (no transcript text) to
    /// `~/Library/Logs/TachyonAI/dictation.log`.
    func log(_ metrics: RealtimeTranscriber.Metrics, audio: AudioCapture.Summary, liveInsert: Bool) {
        guard let committed = metrics.committedAt else { return }
        func ms(_ date: Date?, since origin: Date) -> String {
            date.map { String(Int($0.timeIntervalSince(origin) * 1000)) } ?? "-"
        }
        let line = [
            ISO8601DateFormatter().string(from: committed),
            "warm=\(metrics.wasWarm)",
            "connect_ms=\(ms(metrics.openedAt, since: metrics.startedAt))",
            "spoke_ms=\(ms(committed, since: metrics.startedAt))",
            "first_delta_after_release_ms=\(ms(metrics.firstDeltaAfterCommitAt, since: committed))",
            "last_delta_after_release_ms=\(ms(metrics.lastDeltaAt, since: committed))",
            "confirmed_ms=\(ms(metrics.confirmedAt, since: committed))",
            "pasted_ms=\(ms(metrics.returnedAt, since: committed))",
            "early=\(metrics.returnedEarly)",
            "pasted_len=\(metrics.returnedLength)",
            "confirmed_len=\(metrics.confirmedLength.map(String.init) ?? "-")",
            "match=\(metrics.matchedConfirmed.map(String.init) ?? "-")",
            "live=\(liveInsert)",
            "sent_audio_ms=\(metrics.sentAudioMilliseconds)",
            "mic=\(audio.input)",
            "buffers=\(audio.buffers)",
            "peak=\(String(format: "%.2f", audio.peak))",
            "muted_at_start=\(audio.wasMuted)",
        ].joined(separator: " ") + "\n"

        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/TachyonAI")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dictation.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
