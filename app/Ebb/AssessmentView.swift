import SwiftUI

/// The plan's assessment questions. Submitting saves the answers and asks
/// Gemini (via generate-profile) for a calm profile, then shows the preview.
struct AssessmentView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var answers = AssessmentAnswers()
    @State private var busy = false
    @State private var result: CalmProfileRow?
    @State private var failed = false

    var body: some View {
        EbbScreen {
            if busy {
                making
            } else {
                form
            }
        }
        .ebbNavigation("Calm profile")
        .navigationDestination(item: $result) { row in CalmProfileView(child: child, row: row) }
    }

    @ViewBuilder private var form: some View {
        PageTitle(text: "About \(child.nickname)",
                  subtitle: "About \(child.nickname). There are no wrong answers; you can redo this anytime.")

        multi("What usually comes before a hard moment?", $answers.triggers,
              ["loud_places": "Loud places", "transitions": "Transitions", "crowds": "Crowds",
               "bright_lights": "Bright lights", "being_touched": "Being touched",
               "unexpected_changes": "Unexpected changes", "other": "Other"])

        single("Is \(child.nickname) sensitive to sound?", $answers.soundSensitivity,
               [("very", "Very"), ("a_little", "A little"), ("no", "No")])

        single("Do they like being touched or squeezed when upset?", $answers.touch,
               [("yes", "Yes"), ("no", "No"), ("depends", "Depends")])

        single("Does vibration on the wrist calm or bother them?", $answers.vibration,
               [("calms", "Calms"), ("bothers", "Bothers"), ("not_sure", "Not sure")])

        question("Favourite colours (up to 2)") {
            FlowLayout {
                ForEach(Self.colorOptions, id: \.0) { key, label, color in
                    CheckChip(title: label, isOn: answers.colors.contains(key), swatch: color) {
                        if answers.colors.contains(key) { answers.colors.remove(key) }
                        else if answers.colors.count < 2 { answers.colors.insert(key) }
                    }
                }
            }
        }

        multi("Favourite things", $answers.favoriteThings,
              ["animals": "Animals", "space": "Space", "vehicles": "Vehicles", "nature": "Nature",
               "shapes": "Shapes", "other": "Other"])

        multi("Which sounds do they like?", $answers.soundsLiked,
              ["rain": "Rain", "ocean": "Ocean", "soft_music": "Soft music", "brown_noise": "Brown noise", "none": "None"])

        single("Can they follow a breathing exercise?", $answers.canFollowBreathing,
               [("yes", "Yes"), ("with_help", "With help"), ("no", "No")])

        text("What already helps?", $answers.whatHelps)

        multi("What signs show they are getting upset?", $answers.upsetSigns,
              ["rocking": "Rocking", "hand_flapping": "Hand-flapping", "going_quiet": "Going quiet",
               "shouting": "Shouting", "other": "Other"])

        text("Anything we should never do?", $answers.neverDo)

        if failed {
            ErrorCard(title: "Profile generation error", headline: "Could not make the profile.",
                      message: "Please try again.") { Task { await make() } }
        }

        InsetPanel {
            Text("Your answers and \(child.nickname)'s age band are sent to an AI to suggest settings. Their name is not sent. You approve the result before it reaches the watch.")
                .font(.footnote).foregroundStyle(Ebb.inkSoft)
        }

        Button("Make calm profile") { Task { await make() } }
            .buttonStyle(.ebbPrimary)
    }

    @ViewBuilder private var making: some View {
        PreviewPanel(message: "You're safe. Breathe with me.", colors: answers.colors.map(BreathingPreview.color))
            .padding(.top, 40)
        Text("Making a calm profile...").font(.system(size: 26)).foregroundStyle(Ebb.ink)
        ProgressView().progressViewStyle(.linear).tint(Ebb.teal)
        Footnote(text: "Your answers are being used to suggest settings. You'll review them before anything reaches the watch.")
    }

    private func make() async {
        failed = false
        busy = true
        result = await model.makeCalmProfile(for: child, answers: answers)
        busy = false
        failed = result == nil
    }

    static let colorOptions: [(String, String, Color)] = [
        ("blue", "Blue", Color(hex: 0x5B8DD6)), ("teal", "Teal", Color(hex: 0x4FA3A8)), ("green", "Green", Color(hex: 0x7FB069)),
        ("purple", "Purple", Color(hex: 0x9A7FC4)), ("pink", "Pink", Color(hex: 0xE09AB6)),
        ("yellow", "Yellow", Color(hex: 0xE8C55A)), ("orange", "Orange", Color(hex: 0xE0955A)),
    ]

    private func question<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        EbbCard {
            Text(title).font(.title3).foregroundStyle(Ebb.ink)
            content()
        }
    }

    private func single(_ title: String, _ value: Binding<String>, _ options: [(String, String)]) -> some View {
        question(title) { SegmentChoice(options: options, selection: value) }
    }

    private func multi(_ title: String, _ value: Binding<Set<String>>, _ options: KeyValuePairs<String, String>) -> some View {
        question(title) {
            FlowLayout {
                ForEach(Array(options), id: \.key) { key, label in
                    CheckChip(title: label, isOn: value.wrappedValue.contains(key)) {
                        if value.wrappedValue.contains(key) { value.wrappedValue.remove(key) } else { value.wrappedValue.insert(key) }
                    }
                }
            }
        }
    }

    private func text(_ title: String, _ value: Binding<String>) -> some View {
        question(title) {
            TextField("Short answer", text: value, axis: .vertical)
                .lineLimit(3...5)
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ebb.cardBorder, lineWidth: 1))
                .foregroundStyle(Ebb.ink)
        }
    }
}
