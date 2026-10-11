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
        EbbScreen {
            if loading {
                ProgressView().tint(Ebb.teal).frame(maxWidth: .infinity).padding(.top, 40)
            } else if rerecording {
                RecordVoiceSection(child: child) {
                    rerecording = false
                    await reload()
                }
            } else if state?.hasVoice != true {
                chooseVoiceSection
            } else {
                HStack {
                    StatusChip(text: state?.isStock == true ? "Calm AI voice (female)" : "Your own voice")
                    Spacer()
                }
                clipsSection
                phrasesSection
                manageSection
            }
        }
        .ebbNavigation("Your voice for \(child.nickname)")
        .task { await reload() }
        .disabled(busy)
    }

    /// First visit: a ready-made calm voice, or the parent's own.
    @ViewBuilder private var chooseVoiceSection: some View {
        PageTitle(text: "Which voice should \(child.nickname) hear?")
        EbbCard(title: "A familiar, gentle voice") {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Ebb.teal)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            Text("The AI voice is ready right away, with nothing recorded. Your own voice takes a one-minute recording and is copied by ElevenLabs only with your consent.")
                .foregroundStyle(Ebb.ink)
        }
        Button(busy ? "Setting up..." : "Use a calm AI voice (female)") { Task { await useAIVoice() } }
            .buttonStyle(.ebbPrimary)
        Button { rerecording = true } label: {
            HStack {
                Image(systemName: "mic")
                Spacer()
                Text("Record my own voice")
                Spacer()
                Image(systemName: "mic").hidden()
            }
            .padding(.horizontal, 18)
        }
        .buttonStyle(.ebbSecondary)
        Footnote(text: "Your voice choice belongs to your parent account. You approve calming phrases separately for \(child.nickname)'s watch.")
    }

    private func useAIVoice() async {
        busy = true
        if await model.useStockVoice() { await reload() }
        busy = false
    }

    @ViewBuilder private var phrasesSection: some View {
        PageTitle(text: "Phrases (up to 8, short)")
        ForEach(phrases.indices, id: \.self) { i in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    FieldLabel(text: "Phrase")
                    Spacer()
                    Button { phrases.remove(at: i) } label: { Image(systemName: "xmark").font(.footnote) }
                        .foregroundStyle(Ebb.inkSoft)
                        .buttonStyle(.plain)
                }
                TextField("Phrase", text: $phrases[i]).ebbField()
            }
        }
        if phrases.count < 8 {
            TextField("Add a short phrase", text: $newPhrase).ebbField()
            Button("Add") {
                phrases.append(newPhrase.trimmingCharacters(in: .whitespaces))
                newPhrase = ""
            }
            .buttonStyle(.ebbSecondary)
            .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Button(busy ? "Making clips in your voice..." : "Make clips") {
            Task {
                busy = true
                let cleaned = phrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if await model.makeVoiceClips(for: child, phrases: cleaned) != nil { await reload() }
                busy = false
            }
        }
        .buttonStyle(.ebbPrimary)
        Footnote(text: "Keep them short and calm. New clips replace unapproved ones; approved clips stay until you remove them.")
    }

    @ViewBuilder private var clipsSection: some View {
        if let clips = state?.clips, !clips.isEmpty {
            PageTitle(text: "Listen, then approve",
                      subtitle: "Only approved clips go to \(child.nickname)'s watch, where one plays quietly every few breaths.")
            ForEach(clips) { clip in
                EbbCard {
                    HStack(spacing: 14) {
                        Button {
                            if let url = clip.url { player.play(url) }
                        } label: {
                            Image(systemName: "play")
                                .foregroundStyle(Ebb.teal)
                                .frame(width: 48, height: 48)
                                .background(Ebb.chip, in: Circle())
                                .overlay(Circle().stroke(Ebb.selectedEdge, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(clip.url == nil)
                        Text(clip.phrase).foregroundStyle(Ebb.ink)
                    }
                    Toggle(isOn: Binding(
                        get: { clip.isApproved },
                        set: { on in
                            Task {
                                if await model.setClip(clip, approved: on) { await reload() }
                            }
                        }
                    )) {
                        Text("Approved").font(.subheadline).foregroundStyle(Ebb.ink)
                    }
                    .tint(Ebb.teal)
                }
            }
        }
    }

    private var manageSection: some View {
        EbbCard(title: "Your voice") {
            if state?.isStock == true {
                ActionRow(title: "Use my own voice instead") { rerecording = true }
            } else {
                ActionRow(title: "Record my voice again") { rerecording = true }
                Divider().overlay(Ebb.cardBorder)
                ActionRow(title: "Use the calm AI voice instead") { Task { await useAIVoice() } }
            }
            Divider().overlay(Ebb.cardBorder)
            ActionRow(title: state?.isStock == true ? "Remove voice and clips" : "Delete my voice", icon: "trash") {
                Task {
                    busy = true
                    if await model.deleteVoice() { await reload() }
                    busy = false
                }
            }
            Divider().overlay(Ebb.cardBorder)
            Footnote(text: state?.isStock == true
                     ? "Removes all clips across children on your parent account."
                     : "Deletes your account-wide voice and all clips for every child.")
            Footnote(text: "Removes every clip, including on the watch. Your own voice is also deleted from ElevenLabs.")
            Footnote(text: "Watch changes sync about every 5 minutes when connected.")
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
        PageTitle(text: "Record my own voice")
        Button { consent.toggle() } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: consent ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundStyle(consent ? Ebb.selectedEdge : Ebb.inkSoft)
                Text("This is my own voice. I agree to Ebb sending this recording to ElevenLabs to make a copy of my voice, used only for calming phrases I approve for \(child.nickname)'s watch. The recording itself is not kept, and I can delete my voice at any time.")
                    .font(.subheadline)
                    .foregroundStyle(Ebb.ink)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(consent ? Ebb.selected : Ebb.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(consent ? Ebb.selectedEdge : Ebb.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)

        EbbCard(title: "Recording script") {
            Text("Read this aloud, calmly, for about a minute").font(.title3).foregroundStyle(Ebb.ink)
            Text(Self.script).foregroundStyle(Ebb.ink).lineSpacing(4)
        }

        if recorder.isRecording {
            Button { recorder.stop() } label: {
                HStack {
                    Image(systemName: "stop")
                    Spacer()
                    Text("Stop \(recorder.elapsedText)")
                    Spacer()
                    Image(systemName: "stop").hidden()
                }
                .padding(.horizontal, 18)
            }
            .buttonStyle(.ebbPrimary)
        } else {
            Button { recorder.start() } label: {
                HStack {
                    Image(systemName: "mic")
                    Spacer()
                    Text(recorder.recordingURL == nil ? "Start recording" : "Record again")
                    Spacer()
                    Image(systemName: "mic").hidden()
                }
                .padding(.horizontal, 18)
            }
            .buttonStyle(recorder.recordingURL == nil ? AnyButtonStyle(.ebbPrimary) : AnyButtonStyle(.ebbSecondary))
            .disabled(!consent)
        }

        if let url = recorder.recordingURL, !recorder.isRecording {
            Button(uploading ? "Making your voice..." : "Use this recording (\(recorder.elapsedText))") {
                Task {
                    uploading = true
                    if let data = try? Data(contentsOf: url), await model.cloneVoice(recording: data) {
                        recorder.discard()  // not kept on the phone either
                        await onDone()
                    }
                    uploading = false
                }
            }
            .buttonStyle(.ebbPrimary)
            .disabled(uploading || recorder.seconds < 30)
        }

        if let error = recorder.error {
            ErrorCard(title: "Microphone", message: error)
        } else {
            Footnote(text: "A quiet room works best. At least 30 seconds; about a minute is ideal. Recording stops at 2 minutes.")
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

/// Teal text button row with a trailing icon, inside a card.
private struct ActionRow: View {
    let title: String
    var icon = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Ebb.teal)
                Spacer()
                Image(systemName: icon).foregroundStyle(Ebb.teal)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Lets one button switch between the two Ebb styles.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
