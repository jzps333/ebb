import AVFoundation
import SwiftUI

/// Parent voice: record once (with consent), pick short phrases, listen to each
/// clip in your own voice, and approve the ones the watch may play.
struct VoiceView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var state: VoiceState?
    @State private var loading = true
    @State private var phrases: [String] = []
    @State private var newPhrase = ""
    @State private var busy = false
    @State private var rerecording = false
    @State private var player = ClipPlayer()

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if state?.hasVoice != true || rerecording {
                RecordVoiceSection(child: child) {
                    rerecording = false
                    await reload()
                }
            } else {
                phrasesSection
                clipsSection
                Section {
                    Button("Record my voice again") { rerecording = true }
                    Button("Delete my voice", role: .destructive) {
                        Task {
                            busy = true
                            if await model.deleteVoice() { await reload() }
                            busy = false
                        }
                    }
                } footer: {
                    Text("Deleting removes your voice from ElevenLabs and every clip made from it, including on the watch.")
                }
            }
        }
        .navigationTitle("Your voice for \(child.nickname)")
        .task { await reload() }
        .disabled(busy)
    }

    private var phrasesSection: some View {
        Section {
            ForEach(phrases.indices, id: \.self) { i in
                TextField("Phrase", text: $phrases[i])
            }
            .onDelete { phrases.remove(atOffsets: $0) }
            if phrases.count < 8 {
                HStack {
                    TextField("Add a short phrase", text: $newPhrase)
                    Button("Add") {
                        phrases.append(newPhrase.trimmingCharacters(in: .whitespaces))
                        newPhrase = ""
                    }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Button {
                Task {
                    busy = true
                    let cleaned = phrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if await model.makeVoiceClips(for: child, phrases: cleaned) != nil { await reload() }
                    busy = false
                }
            } label: {
                HStack {
                    if busy { ProgressView().padding(.trailing, 6) }
                    Text(busy ? "Making clips in your voice..." : "Make clips").bold()
                }
            }
        } header: {
            Text("Phrases (up to 8, short)")
        } footer: {
            Text("Keep them short and calm. New clips replace unapproved ones; approved clips stay until you remove them.")
        }
    }

    @ViewBuilder private var clipsSection: some View {
        if let clips = state?.clips, !clips.isEmpty {
            Section {
                ForEach(clips) { clip in
                    HStack {
                        Button {
                            if let url = clip.url { player.play(url) }
                        } label: {
                            Image(systemName: "play.circle.fill").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(clip.url == nil)

                        Text(clip.phrase)
                        Spacer()
                        Toggle("Approved", isOn: Binding(
                            get: { clip.isApproved },
                            set: { on in
                                Task {
                                    if await model.setClip(clip, approved: on) { await reload() }
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Listen, then approve")
            } footer: {
                Text("Only approved clips go to \(child.nickname)'s watch, where one plays quietly every few breaths.")
            }
        }
    }

    private func reload() async {
        state = await model.voiceState(for: child)
        loading = false
        if phrases.isEmpty {
            phrases = ["You're safe.", "Breathe with me.", "I'm right here.", "Slow breath in, and out.", "You're doing great, \(child.nickname)."]
        }
    }
}

/// Consent, a short script to read aloud, and the recorder.
private struct RecordVoiceSection: View {
    @Environment(AppModel.self) private var model
    let child: Child
    let onDone: () async -> Void

    @State private var consent = false
    @State private var recorder = VoiceRecorder()
    @State private var uploading = false

    var body: some View {
        Section {
            Toggle(isOn: $consent) {
                Text("This is my own voice. I agree to Ebb sending this recording to ElevenLabs to make a copy of my voice, used only for calming phrases I approve for \(child.nickname)'s watch. The recording itself is not kept, and I can delete my voice at any time.")
                    .font(.footnote)
            }
        }

        Section("Read this aloud, calmly, for about a minute") {
            Text(Self.script).font(.callout)
        }

        Section {
            if recorder.isRecording {
                Button(role: .destructive) { recorder.stop() } label: {
                    Label("Stop  \(recorder.elapsedText)", systemImage: "stop.circle.fill")
                }
            } else {
                Button { recorder.start() } label: {
                    Label(recorder.recordingURL == nil ? "Start recording" : "Record again", systemImage: "mic.circle.fill")
                }
                .disabled(!consent)
            }

            if let url = recorder.recordingURL, !recorder.isRecording {
                Button {
                    Task {
                        uploading = true
                        if let data = try? Data(contentsOf: url), await model.cloneVoice(recording: data) {
                            recorder.discard()  // not kept on the phone either
                            await onDone()
                        }
                        uploading = false
                    }
                } label: {
                    HStack {
                        if uploading { ProgressView().padding(.trailing, 6) }
                        Text(uploading ? "Making your voice..." : "Use this recording (\(recorder.elapsedText))").bold()
                    }
                }
                .disabled(uploading || recorder.seconds < 30)
            }
        } footer: {
            if let error = recorder.error {
                Text(error).foregroundStyle(.red)
            } else {
                Text("A quiet room works best. At least 30 seconds; about a minute is ideal.")
            }
        }
    }

    static let script = """
    Hi sweetheart. It's me. Let's take a slow breath together. \
    Breathe in through your nose, nice and slow, and let it out gently. \
    You are safe, and I am right here with you. \
    Feelings can be big, and that's okay. They come like waves, and then they get smaller. \
    Let's watch the circle grow, and then shrink. In, and out. \
    Your hands can rest. Your shoulders can drop. \
    You're doing a great job. I'm proud of you. \
    When you're ready, we can try one more slow breath. In, and out. \
    I love you, and I'll see you soon.
    """
}

/// Records mono AAC (.m4a) to a temporary file.
@Observable
final class VoiceRecorder {
    var isRecording = false
    var seconds = 0
    var recordingURL: URL?
    var error: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    var elapsedText: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    func start() {
        error = nil
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.error = "Microphone access is off. Turn it on in Settings > Ebb."
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ebb-voice.m4a")
            recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder?.record(forDuration: 120)
            recordingURL = nil
            seconds = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.seconds += 1
                if self.recorder?.isRecording != true { self.stop() }
            }
        } catch {
            self.error = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        isRecording = false
        recordingURL = recorder?.url
    }

    func discard() {
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }
}

/// Plays a clip from its signed URL.
@Observable
final class ClipPlayer {
    private var player: AVPlayer?

    func play(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = AVPlayer(url: url)
        player?.play()
    }
}
