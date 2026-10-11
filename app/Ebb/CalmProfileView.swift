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
        EbbScreen {
            HStack {
                StatusChip(text: current.isApproved ? "Approved · On the watch" : "Draft · Review before sending")
                Spacer()
            }

            BreathingPreview(profile: p)

            EbbCard(title: "Why these choices") {
                Text("Suggested choices").font(.footnote).foregroundStyle(Ebb.inkSoft)
                Text(p.parentSummary).foregroundStyle(Ebb.ink)
            }

            EbbCard(title: "Settings") {
                setting("Theme", Self.label(p.theme) + (p.colors.isEmpty ? "" : " · " + p.colors.map(Self.label).joined(separator: " + ")))
                setting("Breathing", Self.label(p.breathPattern))
                setting("Vibration", Self.label(p.vibration))
                setting("Sound", p.sound == "none" ? "None" : "\(Self.label(p.sound)) · \(p.volume) volume")
                setting("Starts on its own", Self.autoText(p))
            }

            if current.isApproved {
                InsetPanel {
                    Label("Approved. The watch picks it up within a few seconds.", systemImage: "checkmark.seal")
                        .foregroundStyle(Ebb.teal)
                }
            } else {
                Button(approving ? "Approving..." : "Approve and send to watch") {
                    Task { approving = true; await model.approve(current); approving = false }
                }
                .buttonStyle(.ebbPrimary)
                .disabled(approving)
            }
            Button("Answer the questions again") { retaking = true }
                .buttonStyle(.ebbSecondary)
            Footnote(text: "Version \(current.version). Ebb is a support tool that works alongside \(child.nickname)'s care team.")
        }
        .ebbNavigation("\(child.nickname)'s calm profile")
        .navigationDestination(isPresented: $retaking) { AssessmentView(child: child) }
    }

    private func setting(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.footnote).foregroundStyle(Ebb.inkSoft)
            Text(value).foregroundStyle(Ebb.ink)
        }
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
    @State private var scale: CGFloat = 0

    private var colors: [Color] { profile.colors.map(Self.color) }
    private var main: Color { colors.first ?? .teal }

    var body: some View {
        PreviewPanel(message: profile.calmMessage,
                     phase: profile.breathPattern == "none" ? nil : phase,
                     colors: colors, scale: scale)
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
                    withAnimation(.easeInOut(duration: seconds)) { scale = grow ? 1.0 : 0 }
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

/// Pale blue panel with the soft breathing circle and the calm message.
struct PreviewPanel: View {
    let message: String
    var phase: String?
    var colors: [Color] = []
    var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: colors.isEmpty ? [Color(hex: 0xC3DDE6)] : colors.map { $0.opacity(0.35) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    .frame(width: 176, height: 176)
                    .scaleEffect(0.55 + 0.45 * scale)
                if let phase { Text(phase).font(.subheadline).foregroundStyle(Ebb.chipText) }
            }
            .frame(height: 180)
            Text(message)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(hex: 0x1D4A5C))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Ebb.previewBlue, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xB5D0DA), lineWidth: 1))
    }
}
