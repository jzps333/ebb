import SwiftUI

/// The plan's assessment questions. Submitting saves the answers and asks
/// Gemini (via generate-profile) for a calm profile, then shows the preview.
struct AssessmentView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var answers = AssessmentAnswers()
    @State private var busy = false
    @State private var result: CalmProfileRow?

    var body: some View {
        Form {
            Section {
                Text("About \(child.nickname). There are no wrong answers; you can redo this anytime.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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

            Section {
                ForEach(Self.colorOptions, id: \.0) { key, label, color in
                    Toggle(isOn: Binding(
                        get: { answers.colors.contains(key) },
                        set: { on in
                            if on, answers.colors.count < 2 { answers.colors.insert(key) } else if !on { answers.colors.remove(key) }
                        }
                    )) {
                        Label { Text(label) } icon: { Circle().fill(color).frame(width: 18, height: 18) }
                    }
                }
            } header: { Text("Favourite colours (up to 2)") }

            multi("Favourite things", $answers.favoriteThings,
                  ["animals": "Animals", "space": "Space", "vehicles": "Vehicles", "nature": "Nature",
                   "shapes": "Shapes", "other": "Other"])

            multi("Which sounds do they like?", $answers.soundsLiked,
                  ["rain": "Rain", "ocean": "Ocean", "soft_music": "Soft music", "brown_noise": "Brown noise", "none": "None"])

            single("Can they follow a breathing exercise?", $answers.canFollowBreathing,
                   [("yes", "Yes"), ("with_help", "With help"), ("no", "No")])

            Section("What already helps?") {
                TextField("Short answer", text: $answers.whatHelps, axis: .vertical).lineLimit(2...4)
            }

            multi("What signs show they are getting upset?", $answers.upsetSigns,
                  ["rocking": "Rocking", "hand_flapping": "Hand-flapping", "going_quiet": "Going quiet",
                   "shouting": "Shouting", "other": "Other"])

            Section("Anything we should never do?") {
                TextField("Short answer", text: $answers.neverDo, axis: .vertical).lineLimit(2...4)
            }

            Section {
                Button {
                    Task {
                        busy = true
                        result = await model.makeCalmProfile(for: child, answers: answers)
                        busy = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 6); Text("Making a calm profile...") }
                        else { Text("Make calm profile").bold() }
                        Spacer()
                    }
                }
                .disabled(busy)
            } footer: {
                Text("Your answers and \(child.nickname)'s age band are sent to an AI to suggest settings. Their name is not sent. You approve the result before it reaches the watch.")
            }
        }
        .navigationTitle("Calm profile")
        .navigationDestination(item: $result) { row in CalmProfileView(child: child, row: row) }
    }

    static let colorOptions: [(String, String, Color)] = [
        ("blue", "Blue", .blue), ("teal", "Teal", .teal), ("green", "Green", .green), ("purple", "Purple", .purple),
        ("pink", "Pink", .pink), ("yellow", "Yellow", .yellow), ("orange", "Orange", .orange),
    ]

    private func single(_ title: String, _ value: Binding<String>, _ options: [(String, String)]) -> some View {
        Section(title) {
            Picker(title, selection: value) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func multi(_ title: String, _ value: Binding<Set<String>>, _ options: KeyValuePairs<String, String>) -> some View {
        Section(title) {
            ForEach(Array(options), id: \.key) { key, label in
                Toggle(label, isOn: Binding(
                    get: { value.wrappedValue.contains(key) },
                    set: { on in if on { value.wrappedValue.insert(key) } else { value.wrappedValue.remove(key) } }
                ))
            }
        }
    }
}
