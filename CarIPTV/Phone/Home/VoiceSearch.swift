import AVFoundation
import Observation
import Speech
import SwiftUI

/// Speech to text for the channel search. Listens until a short silence, then hands over the text.
@MainActor @Observable
final class VoiceSearch {
    enum State: Equatable {
        case idle
        case listening
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private var resumePlayback = false
    @ObservationIgnored private var onFinish: ((String) -> Void)?

    func start(onFinish: @escaping (String) -> Void) async {
        self.onFinish = onFinish
        transcript = ""
        guard await Self.authorize() else {
            state = .denied
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            state = .failed(String(localized: "Voice search isn't available right now."))
            return
        }

        // Recording takes over the audio session; a playing channel resumes afterwards.
        resumePlayback = PlaybackController.shared.state == .playing
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            state = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed) }
            }
            stopAfterSilence(seconds: 5)
        } catch {
            cleanUp()
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and delivers what was heard.
    func finish() {
        guard state == .listening else { return }
        cleanUp()
        state = .idle
        onFinish?(transcript)
    }

    func cancel() {
        cleanUp()
        state = .idle
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard state == .listening else { return }
        if let text, !text.isEmpty {
            transcript = text
            stopAfterSilence(seconds: 1.5)
        }
        if isFinal || (failed && !transcript.isEmpty) {
            finish()
        } else if failed {
            cleanUp()
            state = .failed(String(localized: "Couldn't hear anything. Try again."))
        }
    }

    private func stopAfterSilence(seconds: Double) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func cleanUp() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if resumePlayback {
            resumePlayback = false
            PlaybackController.shared.resume()
        }
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Sheet shown while listening.
struct VoiceSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var voice = VoiceSearch()
    let onResult: (String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: voice.state == .listening ? "waveform" : "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: voice.state == .listening)
                .frame(height: 50)

            switch voice.state {
            case .listening, .idle:
                Text(voice.transcript.isEmpty ? String(localized: "Say a channel or show name") : voice.transcript)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                Button("Done") { voice.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(voice.state != .listening)
            case .denied:
                Text("Allow microphone and speech recognition for CarIPTV in Settings to search by voice.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(240)])
        .task {
            await voice.start { text in
                onResult(text)
                dismiss()
            }
        }
        .onDisappear {
            voice.cancel()
        }
    }
}
