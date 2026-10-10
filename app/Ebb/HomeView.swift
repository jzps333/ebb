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
        }
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
