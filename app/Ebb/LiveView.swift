import Charts
import SwiftUI

/// The watch's live agitation over the last 10 minutes, the auto-start
/// switches, and what the learning has changed so far.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var log: [SensitivityChange] = []

    private var isTeacher: Bool { model.profile?.isTeacher == true }
    private var device: Device? { model.devices[child.id] }
    private var settings: ChildSettings? { model.childSettings[child.id] }
    private var samples: [SensorSample] { model.samples[child.id] ?? [] }

    var body: some View {
        EbbScreen {
            PageTitle(text: "Live agitation", subtitle: "How unsettled \(child.nickname) seems right now, measured by the watch.")

            EbbCard(title: "Last 10 minutes") {
                HStack {
                    StatusChip(text: tierText)
                    Spacer()
                    if let a = currentAgitation {
                        Text(String(format: "%.2f", a)).font(.title3.monospacedDigit()).foregroundStyle(Ebb.ink)
                    }
                }
                AgitationChart(samples: samples)
                HStack(spacing: 10) {
                    readout("Movement", value: samples.last?.motion.map { String(format: "%.2f", $0) },
                            z: samples.last?.motionZ)
                    readout("Room", value: samples.last?.noiseDb.map { String(format: "%.0f dB", $0) },
                            z: samples.last?.noiseZ)
                }
                Footnote(text: "1.0 is the auto-start line: calm mode starts when agitation stays above it. At 0.6 the watch gives a slow breathing cue on the wrist. Only numbers are sent, never audio.")
            }

            EbbCard(title: "Auto-start") {
                if let settings {
                    Toggle(isOn: autoBinding(\.autoMotion)) {
                        toggleLabel("Movement", detail: "Rocking or hand-flapping")
                    }
                    .tint(Ebb.teal)
                    Toggle(isOn: autoBinding(\.autoNoise)) {
                        toggleLabel("Loud room", detail: "Noise well above the usual")
                    }
                    .tint(Ebb.teal)
                    InsetPanel {
                        Text("How sensitive").font(.caption).foregroundStyle(Ebb.inkSoft)
                        Text(sensitivityText("Movement", k: settings.motionK)).font(.subheadline).foregroundStyle(Ebb.ink)
                        Text(sensitivityText("Loud room", k: settings.noiseK)).font(.subheadline).foregroundStyle(Ebb.ink)
                    }
                    Footnote(text: "The number is how far above \(child.nickname)'s own normal a signal has to go before calm starts (lower = sooner). Ebb learns it from ratings: a false alarm makes that signal less sensitive, a start that helped makes it a little more sensitive.")
                    if isTeacher {
                        Footnote(text: "Only \(child.nickname)'s parent can turn these on or off.")
                    }
                } else {
                    Text("Settings are not available yet.").foregroundStyle(Ebb.inkSoft)
                }
            }
            .disabled(isTeacher)

            EbbCard(title: "What Ebb learned") {
                if log.isEmpty {
                    Text("Nothing yet. When a teacher rates an automatic start, the change shows up here.")
                        .font(.subheadline).foregroundStyle(Ebb.inkSoft)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(log) { change in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: change.reason == "false alarm" ? "arrow.up.circle" : "arrow.down.circle")
                                    .foregroundStyle(Ebb.teal)
                                Text(Self.describe(change)).font(.subheadline).foregroundStyle(Ebb.ink)
                            }
                        }
                    }
                }
            }
        }
        .ebbNavigation("\(child.nickname) live")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: model.latestMoment) { Task { log = await model.sensitivityLog(for: child) } }
    }

    private func reload() async {
        await model.loadSamples(for: child)
        await model.refreshSettings()
        log = await model.sensitivityLog(for: child)
    }

    // MARK: Parts

    private var currentAgitation: Double? {
        if let d = device, let a = d.agitation, let at = d.agitationAt, Date().timeIntervalSince(at) < 60 { return a }
        return samples.last?.agitation
    }

    private var tierText: String {
        guard let device else { return "No watch" }
        guard device.isOnline else { return "Watch offline" }
        return Device.tierLabel(device.currentTier)
    }

    private func readout(_ title: String, value: String?, z: Double?) -> some View {
        InsetPanel {
            Text(title).font(.caption).foregroundStyle(Ebb.inkSoft)
            Text(value ?? "–").font(.title3.monospacedDigit()).foregroundStyle(Ebb.ink)
            Text(z.map { String(format: "%+.1f above usual", $0) } ?? " ")
                .font(.caption).foregroundStyle(Ebb.inkSoft)
        }
    }

    private func toggleLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Ebb.ink)
            Text(detail).font(.footnote).foregroundStyle(Ebb.inkSoft)
        }
    }

    /// Writes one switch; the other keeps its saved value.
    private func autoBinding(_ key: WritableKeyPath<ChildSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings?[keyPath: key] ?? false },
            set: { on in
                guard var changed = settings else { return }
                changed[keyPath: key] = on
                model.childSettings[child.id] = changed
                Task { await model.setAutoStart(for: child, motion: changed.autoMotion, noise: changed.autoNoise) }
            }
        )
    }

    private func sensitivityText(_ signal: String, k: Double) -> String {
        let word = k < 2.2 ? "quite sensitive" : k <= 3.0 ? "balanced" : "relaxed"
        return "\(signal): \(word) (\(String(format: "%.1f", k)))"
    }

    static func describe(_ c: SensitivityChange) -> String {
        let time = Calendar.current.isDateInToday(c.at)
            ? c.at.formatted(date: .omitted, time: .shortened)
            : c.at.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let signal = c.signal == "motion" ? "movement" : "loud room"
        let what = c.reason == "false alarm" ? "False alarm" : "Helped"
        let effect = c.newK > c.oldK ? "less sensitive" : "a little more sensitive"
        return "\(what) at \(time) → \(signal) \(effect) (\(String(format: "%.1f", c.oldK)) → \(String(format: "%.1f", c.newK)))"
    }
}

/// Line + area of agitation with the 0.6 "rising" and 1.0 "auto-start" lines.
struct AgitationChart: View {
    let samples: [SensorSample]

    var body: some View {
        // Re-render every 5 s so the window keeps sliding even between readings.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let end = context.date
            let start = end.addingTimeInterval(-AppModel.liveWindow)
            let points = samples.filter { $0.at >= start }.compactMap { s in s.agitation.map { (s.at, $0) } }
            let top = max(1.4, (points.map(\.1).max() ?? 0) + 0.1)

            Chart {
                ForEach(points, id: \.0) { at, value in
                    AreaMark(x: .value("Time", at), y: .value("Agitation", value))
                        .foregroundStyle(LinearGradient(colors: [Ebb.teal.opacity(0.35), Ebb.teal.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", at), y: .value("Agitation", value))
                        .foregroundStyle(Ebb.teal)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Auto-start", 1.0))
                    .foregroundStyle(Ebb.tealBottom.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("auto-start line").font(.caption2).foregroundStyle(Ebb.tealBottom)
                    }
                RuleMark(y: .value("Rising", 0.6))
                    .foregroundStyle(Ebb.inkSoft.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("rising").font(.caption2).foregroundStyle(Ebb.inkSoft)
                    }
            }
            .chartXScale(domain: start ... end)
            .chartYScale(domain: 0 ... top)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(Ebb.cardBorder.opacity(0.5))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 0.5, 1.0]) { _ in
                    AxisGridLine().foregroundStyle(Ebb.cardBorder.opacity(0.5))
                    AxisValueLabel()
                }
            }
            .frame(height: 200)
            .overlay {
                if points.isEmpty {
                    Text("No readings in the last 10 minutes.\nThe watch sends them while it is awake.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Ebb.inkSoft)
                }
            }
        }
    }
}
