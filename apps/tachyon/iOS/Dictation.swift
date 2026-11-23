import AVFoundation
import Foundation

/// Voice input for the message field: tap the microphone, speak, tap again.
@MainActor
final class Dictation: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var level: Float = 0
    /// The words heard so far, shown while speaking.
    @Published private(set) var partial = ""
    @Published var error: String?

    private let auth: AuthService
    private let api: TachyonAPI
    private let audio = AudioCapture()
    private var transcriber: RealtimeTranscriber?

    enum DictationError: LocalizedError {
        case microphoneDenied
        case silentMicrophone

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "マイクの使用が許可されていません (設定アプリで許可してください)"
            case .silentMicrophone: return "マイクから音が届いていません"
            }
        }
    }

    init(auth: AuthService, api: TachyonAPI) {
        self.auth = auth
        self.api = api
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.level = level }
        }
        audio.onChunk = { [weak self] chunk in
            DispatchQueue.main.async { self?.transcriber?.append(chunk) }
        }
    }

    /// Starts recording, or stops and hands the transcript to `deliver`.
    func toggle(deliver: @escaping (String) -> Void) {
        switch phase {
        case .idle: start()
        case .recording: stop(deliver: deliver)
        case .transcribing: break
        }
    }

    private func start() {
        error = nil
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                error = DictationError.microphoneDenied.localizedDescription
                return
            }
            do {
                try audio.start()
            } catch {
                self.error = error.localizedDescription
                return
            }
            let auth = self.auth
            let transcriber = RealtimeTranscriber(loadConfig: { try await auth.config() }, tuning: .dictation())
            transcriber.beginTurn()
            transcriber.onPartial = { [weak self] text in self?.partial = text }
            transcriber.start()
            self.transcriber = transcriber
            partial = ""
            level = 0
            phase = .recording
        }
    }

    private func stop(deliver: @escaping (String) -> Void) {
        guard let transcriber else { return }
        let summary = audio.stop()
        phase = .transcribing

        // Let the last audio chunks queued on the main thread reach the transcriber first.
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    let text = await self.tidied(try await transcriber.finish())
                    if !text.isEmpty {
                        DictationHistory.shared.add(text)
                        Vocabulary.shared.noteDictated(text)
                        deliver(text)
                    } else if summary.wasSilent {
                        self.error = DictationError.silentMicrophone.localizedDescription
                    }
                } catch {
                    self.error = error.localizedDescription
                }
                self.transcriber = nil
                self.partial = ""
                self.phase = .idle
            }
        }
    }

    /// The same cleanup modes as on the Mac; a failed LLM request falls back to the in-app one.
    private func tidied(_ raw: String) async -> String {
        let vocabulary = Vocabulary.shared
        let local = vocabulary.apply(to: Preferences.cleanupMode == .off
            ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            : TranscriptCleaner.clean(raw))
        guard Preferences.cleanupMode == .thorough, raw.count >= 8 else { return local }
        guard let cleaned = try? await api.cleanUp(
            transcript: raw, background: vocabulary.background,
            terms: vocabulary.replacements.map(\.written)),
            !cleaned.isEmpty, cleaned.count <= raw.count * 2 + 20 else { return local }
        return vocabulary.apply(to: cleaned)
    }
}
