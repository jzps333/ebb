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
    @State private var loading = true

    var body: some View {
        List {
            if !loading && moments.isEmpty {
                Text("No calm moments today.").foregroundStyle(.secondary)
            }
            ForEach(moments) { m in
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppModel.describe(m, sceneTitle: model.sceneTitle(m.sceneId)))
                    RatingControl(moment: m, canRate: model.profile?.isTeacher == true)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("\(child.nickname) today")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: model.latestMoment) { Task { await reload() } }
    }

    private func reload() async {
        await model.loadSceneLibrary()
        moments = await model.moments(for: child)
        loading = false
    }
}
