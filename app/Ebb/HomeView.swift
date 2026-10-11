import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPair = false
    @State private var showingAccount = false

    private var isTeacher: Bool { model.profile?.isTeacher == true }

    var body: some View {
        NavigationStack {
            EbbScreen {
                PageTitle(text: isTeacher ? "My class" : "My children",
                          subtitle: "\(model.profile?.displayName ?? "") · \(isTeacher ? "Teacher" : "Parent")")

                Button { showingPair = true } label: {
                    HStack {
                        Image(systemName: "viewfinder")
                        Spacer()
                        Text("Pair watch")
                        Spacer()
                        Image(systemName: "viewfinder").hidden()
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.ebbSecondary)

                if model.children.isEmpty && !model.isLoading {
                    EbbCard(title: "Getting started") {
                        Image(systemName: "applewatch")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Ebb.teal)
                            .frame(maxWidth: .infinity, minHeight: 150)
                            .background(Ebb.previewBlue, in: RoundedRectangle(cornerRadius: 12))
                        Text("No students yet").font(.title3).foregroundStyle(Ebb.ink)
                        Text(isTeacher ? "Scan a student's watch while the parent is pairing it."
                                       : "Tap Pair watch and scan the QR code on the watch.")
                            .foregroundStyle(Ebb.ink)
                    }
                }

                ForEach(model.children) { child in
                    ChildCard(child: child)
                }

                if isTeacher && !model.children.isEmpty {
                    Footnote(text: "The parent sets up each child's calm profile and voice. You can start or stop calm mode here, rate calm moments and add notes.")
                }
            }
            .refreshable { await model.reload() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("ebb").font(.title2.bold()).foregroundStyle(Ebb.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAccount = true } label: {
                        Image(systemName: "person")
                            .foregroundStyle(Ebb.ink)
                            .frame(width: 40, height: 40)
                            .background(Ebb.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ebb.cardBorder, lineWidth: 1))
                    }
                }
            }
            .sheet(isPresented: $showingPair) { PairView() }
            .overlay(alignment: .top) { AlertBanner() }
            .overlay { if showingAccount { AccountMenu(isShowing: $showingAccount) } }
        }
        .tint(Ebb.teal)
    }
}

/// The "Account" card that drops over the home screen.
struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var isShowing: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { isShowing = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Account").font(.title3).foregroundStyle(Ebb.ink)
                    Spacer()
                    Button { isShowing = false } label: { Image(systemName: "xmark").foregroundStyle(Ebb.ink) }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(Ebb.headerGradient)

                VStack(alignment: .leading, spacing: 14) {
                    Text(model.profile?.displayName ?? "").font(.title2).foregroundStyle(Ebb.ink)
                    Text(model.profile?.isTeacher == true ? "Teacher" : "Parent").foregroundStyle(Ebb.inkSoft)
                    Button("Sign out") {
                        isShowing = false
                        Task { await model.signOut() }
                    }
                    .buttonStyle(.ebbSecondary)
                }
                .padding(18)
            }
            .background(Ebb.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Ebb.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }
}

struct ChildCard: View {
    @Environment(AppModel.self) private var model
    let child: Child

    private var device: Device? { model.devices[child.id] }
    private var summary: DaySummary? { model.today[child.id] }
    private var busy: Bool { model.sendingCommandFor == child.id }
    private var isTeacher: Bool { model.profile?.isTeacher == true }

    var body: some View {
        EbbCard(title: "\(child.nickname)'s watch") {
            HStack(spacing: 14) {
                Avatar(name: child.nickname)
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.nickname).font(.title3).foregroundStyle(Ebb.ink)
                    Text("Age \(child.ageBand.replacingOccurrences(of: "-", with: "–"))").font(.footnote).foregroundStyle(Ebb.inkSoft)
                }
                Spacer()
                Image(systemName: "applewatch").font(.title3).foregroundStyle(Ebb.teal)
            }

            StatusChip(text: statusText)

            HStack(spacing: 12) {
                Button(busy ? "Sending..." : "Start calm") { Task { await model.send("start_calm", to: child) } }
                    .buttonStyle(.ebbPrimary)
                Button("Stop") { Task { await model.send("stop_calm", to: child) } }
                    .buttonStyle(.ebbSecondary)
            }
            .disabled(device == nil || busy)

            InsetPanel { todaySummary }

            if let moment = model.latestMoment[child.id] {
                LatestMomentRow(moment: moment, canRate: isTeacher)
            }

            VStack(spacing: 0) {
                LinkRow(title: "Calm moments today") { MomentsView(child: child) }
                Divider()
                LinkRow(title: "This week's scenes") { ScenesView(child: child) }
                if !isTeacher {
                    Divider()
                    LinkRow(title: profileStatus) {
                        if let row = model.calmProfiles[child.id] {
                            CalmProfileView(child: child, row: row)
                        } else {
                            AssessmentView(child: child)
                        }
                    }
                    Divider()
                    LinkRow(title: "Your voice on the watch") { VoiceView(child: child) }
                }
            }
        }
    }

    private var statusText: String {
        guard let device else { return "No watch" }
        if busy { return "Command submitting" }
        if device.calmActive { return "Calm mode on" }
        return device.isOnline ? "Watch online" : "Watch offline"
    }

    private var profileStatus: String {
        guard let row = model.calmProfiles[child.id] else { return "Set up calm profile" }
        return row.isApproved ? "Calm profile: \(CalmProfileView.label(row.profile.theme))" : "Calm profile waiting for your approval"
    }

    @ViewBuilder private var todaySummary: some View {
        if let s = summary {
            Text("Today: \(s.sessions) calm \(s.sessions == 1 ? "session" : "sessions"), \(s.calmMinutes, specifier: "%.0f") min")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Ebb.ink)
            Text(breakdown(s)).font(.footnote).foregroundStyle(Ebb.inkSoft)
            if s.helpedYes + s.helpedNo > 0 {
                Text("Helped \(s.helpedYes) of \(s.helpedYes + s.helpedNo) rated").font(.footnote).foregroundStyle(Ebb.inkSoft)
            }
        } else {
            Text("Today: no calm sessions yet").font(.subheadline).foregroundStyle(Ebb.inkSoft)
        }
    }

    private func breakdown(_ s: DaySummary) -> String {
        [(s.byTeacher, "teacher"), (s.byChildTap, "tapped watch"), (s.byMotion, "movement"), (s.byNoise, "loud room")]
            .filter { $0.0 > 0 }
            .map { "\($0.1) · \($0.0)" }
            .joined(separator: "    ")
    }
}

/// "Sam started calm mode" as a pale blue card dropping in from the top.
struct AlertBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "water.waves")
                Text(text).font(.subheadline)
            }
            .foregroundStyle(Ebb.chipText)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ebb.selected, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ebb.selectedEdge.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal, 20)
            .padding(.top, 6)
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
            Text("Last calm moment").font(.caption).foregroundStyle(Ebb.inkSoft)
            Text(AppModel.describe(moment, sceneTitle: model.sceneTitle(moment.sceneId)))
                .font(.subheadline).foregroundStyle(Ebb.ink)
            RatingControl(moment: moment, canRate: canRate)
            if canRate && moment.helped != nil {
                Button("Add a journal note →") { writing = true }
                    .font(.subheadline)
                    .foregroundStyle(Ebb.teal)
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
            StatusChip(text: helped ? "Helped" : "Didn't help")
        } else if canRate {
            HStack(spacing: 10) {
                Text("Did it help?").font(.subheadline).foregroundStyle(Ebb.ink)
                Spacer()
                thumb("hand.thumbsup", helped: true)
                thumb("hand.thumbsdown", helped: false)
            }
        } else {
            Text("Not rated yet").font(.footnote).foregroundStyle(Ebb.inkSoft)
        }
    }

    private func thumb(_ icon: String, helped: Bool) -> some View {
        Button { Task { await model.rate(moment, helped: helped) } } label: {
            Image(systemName: icon)
                .foregroundStyle(Ebb.teal)
                .frame(width: 48, height: 40)
                .background(Ebb.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ebb.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        EbbScreen {
            PageTitle(text: "Calm moments today")
            if !loading && moments.isEmpty {
                EbbCard { Text("No calm moments today.").foregroundStyle(Ebb.inkSoft) }
            }
            ForEach(moments) { m in
                EbbCard(title: m.startedAt.formatted(date: .omitted, time: .shortened)) {
                    Text(AppModel.describe(m, sceneTitle: model.sceneTitle(m.sceneId))).foregroundStyle(Ebb.ink)
                    RatingControl(moment: m, canRate: isTeacher)
                    if let note = notes[m.id] {
                        InsetPanel {
                            Text("Teacher's note").font(.caption).foregroundStyle(Ebb.inkSoft)
                            Text(note.body).font(.subheadline).foregroundStyle(Ebb.ink)
                        }
                    }
                    if isTeacher {
                        Button(notes[m.id] == nil ? "Add note" : "Edit note") { writingFor = m }
                            .buttonStyle(.ebbSecondary)
                    }
                }
            }
        }
        .ebbNavigation("\(child.nickname) today")
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
            EbbScreen {
                PageTitle(text: "Journal note")
                Text(AppModel.describe(moment, sceneTitle: model.sceneTitle(moment.sceneId)))
                    .font(.subheadline).foregroundStyle(Ebb.inkSoft)
                EbbCard(title: "Tap a prompt to add it") {
                    FlowLayout {
                        ForEach(Self.prompts, id: \.self) { p in
                            CheckChip(title: p.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":")),
                                      isOn: false) {
                                text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + p
                            }
                        }
                    }
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 200)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ebb.cardBorder, lineWidth: 1))
                Footnote(text: "\(child.nickname)'s parent can read this note and ask questions about it.")
            }
            .ebbNavigation("Journal note")
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
