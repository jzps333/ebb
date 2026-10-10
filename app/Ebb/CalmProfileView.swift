import SwiftUI

/// Preview of a calm profile the way the watch will run it, with Approve.
struct CalmProfileView: View {
    @Environment(AppModel.self) private var model
    let child: Child
    let row: CalmProfileRow

    @State private var approving = false
    @State private var retaking = false

    /// The newest copy (Approve changes the status after this view opened).
    private var current: CalmProfileRow { model.calmProfiles[child.id]?.id == row.id ? model.calmProfiles[child.id]! : row }
    private var p: CalmProfile { current.profile }

    var body: some View {
        List {
            Section {
                BreathingPreview(profile: p)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
            }

            Section("Why these choices") {
                Text(p.parentSummary)
            }

            Section("Settings") {
                row("Theme", Self.label(p.theme), "sparkles")
                row("Breathing", Self.label(p.breathPattern), "wind")
                row("Vibration", Self.label(p.vibration), "iphone.radiowaves.left.and.right")
                row("Sound", p.sound == "none" ? "None" : "\(Self.label(p.sound)), \(p.volume) volume", "speaker.wave.2")
                row("Starts on its own", Self.autoText(p), "figure.walk.motion")
            }

            Section {
                if current.isApproved {
                    Label("Approved. The watch picks it up within a few seconds.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { approving = true; await model.approve(current); approving = false }
                    } label: {
                        HStack { Spacer(); Text(approving ? "Approving..." : "Approve and send to watch").bold(); Spacer() }
                    }
                    .disabled(approving)
                }
                Button("Answer the questions again") { retaking = true }
            } footer: {
                Text("Version \(current.version). Ebb is a support tool that works alongside \(child.nickname)'s care team.")
            }
        }
        .navigationTitle("\(child.nickname)'s calm profile")
        .navigationDestination(isPresented: $retaking) { AssessmentView(child: child) }
    }

    private func row(_ title: String, _ value: String, _ icon: String) -> some View {
        LabeledContent { Text(value) } label: { Label(title, systemImage: icon) }
    }

    static func label(_ raw: String) -> String {
        switch raw {
        case "slow_4_4": return "Slow (in 4, out 4)"
        case "slow_4_6": return "Slow (in 4, out 6)"
        case "box_4_4_4_4": return "Box (in 4, hold 4, out 4, hold 4)"
        case "none": return "No breathing guide"
        case "soft_piano": return "Soft piano"
        case "brown_noise": return "Brown noise"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static func autoText(_ p: CalmProfile) -> String {
        switch (p.autoTriggers.motion, p.autoTriggers.noise) {
        case (true, true): return "Movement or loud room"
        case (true, false): return "Movement"
        case (false, true): return "Loud room"
        default: return "Only when asked"
        }
    }
}

/// A phone-sized copy of the watch's calm screen: theme colours, the calm
/// message, and the circle breathing at the profile's pace.
struct BreathingPreview: View {
    let profile: CalmProfile
    @State private var phase = "Breathe in"
    @State private var scale: CGFloat = 0.45

    private var colors: [Color] { profile.colors.map(Self.color) }
    private var main: Color { colors.first ?? .teal }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, main.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(RadialGradient(colors: [colors.last ?? main, main], center: .center, startRadius: 5, endRadius: 120))
                .frame(width: 200, height: 200)
                .scaleEffect(scale)
            VStack {
                Spacer()
                Text(profile.breathPattern == "none" ? "" : phase).font(.headline).foregroundStyle(.white.opacity(0.9))
                Text(profile.calmMessage).font(.subheadline).foregroundStyle(.white).padding(.bottom, 14)
            }
        }
        .task(id: profile) { await breathe() }
    }

    /// Steps of (label, seconds, grow?) per pattern; nil grow = hold.
    private var steps: [(String, Double, Bool?)] {
        switch profile.breathPattern {
        case "slow_4_4": return [("Breathe in", 4, true), ("Breathe out", 4, false)]
        case "box_4_4_4_4": return [("Breathe in", 4, true), ("Hold", 4, nil), ("Breathe out", 4, false), ("Hold", 4, nil)]
        case "none": return [("", 6, true), ("", 6, false)]  // slow gentle pulse, no counting
        default: return [("Breathe in", 4, true), ("Breathe out", 6, false)]
        }
    }

    private func breathe() async {
        while !Task.isCancelled {
            for (label, seconds, grow) in steps {
                phase = label
                if let grow {
                    withAnimation(.easeInOut(duration: seconds)) { scale = grow ? 1.0 : 0.45 }
                }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
            }
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "teal": return .teal
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        case "orange": return .orange
        default: return .teal
        }
    }
}
