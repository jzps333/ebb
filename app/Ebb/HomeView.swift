import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPair = false

    var body: some View {
        NavigationStack {
            List {
                if model.children.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        "No students yet",
                        systemImage: "applewatch",
                        description: Text(model.profile?.isTeacher == true
                            ? "Scan a student's watch while the parent is pairing it."
                            : "Tap Pair watch and scan the QR code on the watch.")
                    )
                }
                ForEach(model.children) { child in
                    ChildCard(child: child)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.reload() }
            .navigationTitle(model.profile?.isTeacher == true ? "My class" : "My children")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingPair = true } label: {
                        Label("Pair watch", systemImage: "qrcode.viewfinder")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if let name = model.profile?.displayName {
                            Text("\(name) (\(model.profile?.role ?? ""))")
                        }
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showingPair) { PairView() }
            .overlay(alignment: .top) { AlertBanner() }
        }
    }
}

struct ChildCard: View {
    @Environment(AppModel.self) private var model
    let child: Child

    private var device: Device? { model.devices[child.id] }
    private var summary: DaySummary? { model.today[child.id] }
    private var busy: Bool { model.sendingCommandFor == child.id }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(child.nickname).font(.title2.bold())
                    Spacer()
                    watchStatus
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await model.send("start_calm", to: child) }
                    } label: {
                        Label("Start calm", systemImage: "wind")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)

                    Button {
                        Task { await model.send("stop_calm", to: child) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(device == nil || busy)

                todaySummary
            }
            .padding(.vertical, 4)

            // The teacher saw the calm moment at school, so the teacher rates it.
            if let moment = model.latestMoment[child.id] {
                LatestMomentRow(moment: moment, canRate: model.profile?.isTeacher == true)
            }

            NavigationLink {
                MomentsView(child: child)
            } label: {
                Label("Calm moments today", systemImage: "list.bullet.rectangle")
            }

            NavigationLink {
                ScenesView(child: child)
            } label: {
                Label("This week's scenes", systemImage: "play.rectangle.on.rectangle")
            }

            if model.profile?.isTeacher != true {
                NavigationLink {
                    if let row = model.calmProfiles[child.id] {
                        CalmProfileView(child: child, row: row)
                    } else {
                        AssessmentView(child: child)
                    }
                } label: {
                    Label(profileStatus, systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    VoiceView(child: child)
                } label: {
                    Label("Your voice on the watch", systemImage: "waveform")
                }
            }
        }
    }

    private var profileStatus: String {
        guard let row = model.calmProfiles[child.id] else { return "Set up calm profile" }
        return row.isApproved ? "Calm profile: \(CalmProfileView.label(row.profile.theme))" : "Calm profile waiting for your approval"
    }

    @ViewBuilder private var watchStatus: some View {
        if let device {
            if device.calmActive {
                Label("Calm mode on", systemImage: "circle.fill").foregroundStyle(.teal)
            } else if device.isOnline {
                Label("Watch online", systemImage: "circle.fill").foregroundStyle(.green)
            } else {
                Label("Watch offline", systemImage: "circle").foregroundStyle(.secondary)
            }
        } else {
            Label("No watch", systemImage: "applewatch.slash").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var todaySummary: some View {
        if let s = summary {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today: \(s.sessions) calm \(s.sessions == 1 ? "session" : "sessions"), \(s.calmMinutes, specifier: "%.0f") min")
                    .font(.subheadline.weight(.semibold))
                Text(breakdown(s)).font(.footnote).foregroundStyle(.secondary)
                if s.helpedYes + s.helpedNo > 0 {
                    Text("Helped \(s.helpedYes) of \(s.helpedYes + s.helpedNo) rated")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Today: no calm sessions yet").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func breakdown(_ s: DaySummary) -> String {
        [(s.byTeacher, "teacher"), (s.byChildTap, "tapped watch"), (s.byMotion, "movement"), (s.byNoise, "loud room")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
    }
}

struct AlertBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.banner {
            Label(text, systemImage: "bell.badge.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.teal, in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring, value: model.banner)
        }
    }
}

/// The latest calm moment, which one it was, and its rating.
struct LatestMomentRow: View {
    @Environment(AppModel.self) private var model
    let moment: CalmMoment
    let canRate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last calm moment").font(.caption).foregroundStyle(.secondary)
            Text(AppModel.describe(moment, sceneTitle: model.sceneTitle(moment.sceneId))).font(.subheadline)
            RatingControl(moment: moment, canRate: canRate)
            if canRate && moment.helped != nil {
                Button("Add a journal note →") { writing = true }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .sheet(isPresented: $writing) {
            if let child = model.children.first(where: { $0.id == moment.childId }) {
                NoteLoader(child: child, moment: moment)
            }
        }
    }

    @State private var writing = false
}

/// Fetches any existing note for the moment, then shows the note sheet.
private struct NoteLoader: View {
    @Environment(AppModel.self) private var model
    let child: Child
    let moment: CalmMoment
    @State private var existing: JournalNote?
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                JournalNoteSheet(child: child, moment: moment, existing: existing) {}
            } else {
                ProgressView()
            }
        }
        .task {
            existing = await model.notes(for: [moment])[moment.id]
            loaded = true
        }
    }
}

/// Thumbs for the teacher until rated; afterwards the rating, for everyone.
struct RatingControl: View {
    @Environment(AppModel.self) private var model
    let moment: CalmMoment
    let canRate: Bool

    var body: some View {
        if let helped = moment.helped {
            Label(helped ? "Helped" : "Didn't help", systemImage: helped ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .font(.footnote)
                .foregroundStyle(helped ? .green : .orange)
        } else if canRate {
            HStack {
                Text("Did it help?").font(.footnote)
                Spacer()
                Button { Task { await model.rate(moment, helped: true) } } label: { Image(systemName: "hand.thumbsup") }
                    .buttonStyle(.bordered)
                Button { Task { await model.rate(moment, helped: false) } } label: { Image(systemName: "hand.thumbsdown") }
                    .buttonStyle(.bordered)
            }
        } else {
            Text("Not rated yet").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Today's calm moments with scene, length, trigger and rating; teachers rate here.
struct MomentsView: View {
    @Environment(AppModel.self) private var model
    let child: Child
    @State private var moments: [CalmMoment] = []
    @State private var notes: [UUID: JournalNote] = [:]
    @State private var loading = true
    @State private var writingFor: CalmMoment?

    private var isTeacher: Bool { model.profile?.isTeacher == true }

    var body: some View {
        List {
            if !loading && moments.isEmpty {
                Text("No calm moments today.").foregroundStyle(.secondary)
            }
            ForEach(moments) { m in
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppModel.describe(m, sceneTitle: model.sceneTitle(m.sceneId)))
                    RatingControl(moment: m, canRate: isTeacher)
                    if let note = notes[m.id] {
                        Text(note.body)
                            .font(.footnote)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if isTeacher {
                        Button(notes[m.id] == nil ? "Add note" : "Edit note") { writingFor = m }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("\(child.nickname) today")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: model.latestMoment) { Task { await reload() } }
        .sheet(item: $writingFor) { m in
            JournalNoteSheet(child: child, moment: m, existing: notes[m.id]) {
                Task { await reload() }
            }
        }
    }

    private func reload() async {
        await model.loadSceneLibrary()
        moments = await model.moments(for: child)
        notes = await model.notes(for: moments)
        loading = false
    }
}

/// The teacher's journal note for one calm moment, with tap-to-add prompts.
/// Saved to journal_entries, so it also shows on the parent's website.
struct JournalNoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let child: Child
    let moment: CalmMoment
    let existing: JournalNote?
    let onSaved: () -> Void

    @State private var text = ""
    @State private var saving = false

    static let prompts = [
        "What happened before: ",
        "What helped: ",
        "How it ended: ",
        "Next time, try: ",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AppModel.describe(moment, sceneTitle: model.sceneTitle(moment.sceneId)))
                        .font(.subheadline)
                }
                Section("Tap a prompt to add it") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.prompts, id: \.self) { p in
                                Button(p.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))) {
                                    text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + p
                                }
                                .buttonStyle(.bordered)
                                .font(.footnote)
                            }
                        }
                    }
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 180)
                } footer: {
                    Text("\(child.nickname)'s parent can read this note and ask questions about it.")
                }
            }
            .navigationTitle("Journal note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            if await model.saveNote(text, for: moment, existing: existing) {
                                onSaved()
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = existing?.body ?? "" }
        }
    }
}
