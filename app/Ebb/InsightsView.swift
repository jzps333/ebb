import Charts
import SwiftUI

/// When calm moments happen, which scenes help, the next risky hours, and
/// the AI weekly report.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var pattern: PatternStats?
    @State private var scenes: [SceneStat] = []
    @State private var forecast: [RiskHour] = []
    @State private var insight: WeeklyInsight?
    @State private var bucket = "all"
    @State private var loading = true
    @State private var writing = false
    @State private var writeError: String?

    var body: some View {
        EbbScreen {
            PageTitle(text: "Patterns & insights", subtitle: "From \(child.nickname)'s calm moments and the teacher's ratings.")

            EbbCard(title: "When calm moments happen") { heatmap }
            EbbCard(title: "What helps") { whatHelps }
            EbbCard(title: "Next 8 hours") { riskForecast }
            reportCard
        }
        .ebbNavigation("\(child.nickname)'s patterns")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        async let p = model.patternStats(for: child)
        async let s = model.sceneStats(for: child)
        async let f = model.riskForecast(for: child)
        async let i = model.weeklyInsight(for: child)
        pattern = await p
        scenes = await s
        forecast = await f
        insight = await i
        loading = false
    }

    // MARK: (a) Weekday x hour heatmap

    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    @ViewBuilder private var heatmap: some View {
        if let pattern, pattern.total > 0 {
            let counts = Dictionary(pattern.heatmap.map { ("\($0.dow)-\($0.hour)", $0.count) }, uniquingKeysWith: +)
            let hours = Array(min(7, pattern.heatmap.map(\.hour).min() ?? 7) ... max(18, pattern.heatmap.map(\.hour).max() ?? 18))
            let peak = max(1, pattern.heatmap.map(\.count).max() ?? 1)
            let cells = (1 ... 7).flatMap { dow in
                hours.map { PatternStats.Cell(dow: dow, hour: $0, count: counts["\(dow)-\($0)"] ?? 0) }
            }

            Chart {
                ForEach(cells, id: \.self) { cell in
                    RectangleMark(x: .value("Hour", Self.hourLabel(cell.hour)), y: .value("Day", Self.days[cell.dow - 1]),
                                  width: .ratio(0.9), height: .ratio(0.85))
                        .foregroundStyle(cell.count == 0 ? Ebb.panel : Ebb.teal.opacity(0.2 + 0.8 * Double(cell.count) / Double(peak)))
                        .cornerRadius(3)
                }
            }
            .chartXScale(domain: hours.map(Self.hourLabel))
            .chartYScale(domain: Self.days)
            .chartXAxis {
                AxisMarks(values: hours.filter { $0 % 2 == 0 }.map(Self.hourLabel)) { _ in AxisValueLabel() }
            }
            .frame(height: 210)

            if let b = pattern.busiest {
                InsetPanel {
                    Text("Busiest time").font(.caption).foregroundStyle(Ebb.inkSoft)
                    Text("\(Self.days[b.dow - 1]) around \(Self.hourRange(b.hour)) · \(b.count) calm \(b.count == 1 ? "moment" : "moments")")
                        .font(.subheadline).foregroundStyle(Ebb.ink)
                }
            }
            Footnote(text: "Last \(pattern.days) days, \(pattern.total) calm moments" +
                     (pattern.avgMinutes.map { String(format: ", about %.0f min each", $0) } ?? "") +
                     ". Darker squares = more calm moments.")
        } else {
            Text(loading ? "Loading..." : "No calm moments in the last 4 weeks yet.").foregroundStyle(Ebb.inkSoft)
        }
    }

    // MARK: (b) Scene posterior with 90% band

    private var bucketScenes: [SceneStat] {
        scenes.filter { $0.bucket == bucket && $0.rated > 0 }
            .sorted { $0.mean > $1.mean }
            .prefix(8)
            .map { $0 }
    }

    @ViewBuilder private var whatHelps: some View {
        SegmentChoice(options: [("all", "All day"), ("morning", "Morning"), ("afternoon", "Afternoon"), ("evening", "Evening")],
                      selection: $bucket)
        let rows = bucketScenes
        if rows.isEmpty {
            Text(loading ? "Loading..." : "No rated calm moments for this time of day yet.")
                .font(.subheadline).foregroundStyle(Ebb.inkSoft)
        } else {
            Chart {
                ForEach(rows, id: \.sceneId) { s in
                    BarMark(xStart: .value("Low", s.low), xEnd: .value("High", s.high), y: .value("Scene", s.title), height: .ratio(0.5))
                        .foregroundStyle(Ebb.chip)
                    RuleMark(xStart: .value("Low", s.low), xEnd: .value("High", s.high), y: .value("Scene", s.title))
                        .foregroundStyle(Ebb.selectedEdge.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Chance it helps", s.mean), y: .value("Scene", s.title))
                        .foregroundStyle(Ebb.teal)
                        .symbolSize(70)
                        .annotation(position: .trailing, spacing: 6) {
                            Text("\(s.helped)/\(s.rated)").font(.caption2).foregroundStyle(Ebb.inkSoft)
                        }
                }
            }
            .chartXScale(domain: 0 ... 1)
            .chartXAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { v in
                    AxisGridLine().foregroundStyle(Ebb.cardBorder.opacity(0.5))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d * 100))%") } }
                }
            }
            .frame(height: CGFloat(rows.count) * 38 + 30)
            Footnote(text: "Dot = Ebb's best guess of how often the scene helps; the band is where the real answer probably is (90%). \"3/4\" means it helped 3 of 4 rated times.")
        }
        Footnote(text: "Ebb tries promising scenes more often and learns from every rating (Thompson sampling), so a scene with few ratings still gets a turn.")
    }

    // MARK: (c) Risk forecast

    private static func color(_ level: String) -> Color {
        switch level {
        case "high": return Color(hex: 0xC8775A)
        case "medium": return Color(hex: 0xD9B45B)
        default: return Color(hex: 0xA9C9A0)
        }
    }

    @ViewBuilder private var riskForecast: some View {
        if forecast.isEmpty {
            Text(loading ? "Loading..." : "No forecast yet.").foregroundStyle(Ebb.inkSoft)
        } else {
            let next = forecast.first { $0.level == "high" } ?? forecast.first { $0.level == "medium" }
            InsetPanel {
                Text("Next risky hour").font(.caption).foregroundStyle(Ebb.inkSoft)
                if let next {
                    Text("\(Self.clockRange(next.hourStart)) · about \(Int((next.risk * 100).rounded()))% chance of a calm moment")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Ebb.ink)
                } else {
                    Text("Nothing stands out in the next 8 hours.").font(.subheadline).foregroundStyle(Ebb.ink)
                }
            }
            Chart {
                ForEach(forecast) { h in
                    BarMark(x: .value("Hour", h.hourStart.formatted(.dateTime.hour())), y: .value("Chance", h.risk))
                        .foregroundStyle(Self.color(h.level))
                        .cornerRadius(4)
                }
            }
            .chartYScale(domain: 0 ... 1)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 0.5, 1]) { v in
                    AxisGridLine().foregroundStyle(Ebb.cardBorder.opacity(0.5))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d * 100))%") } }
                }
            }
            .frame(height: 160)
            HStack(spacing: 14) {
                ForEach(["low", "medium", "high"], id: \.self) { level in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Self.color(level)).frame(width: 12, height: 12)
                        Text(level.capitalized).font(.caption).foregroundStyle(Ebb.inkSoft)
                    }
                }
            }
            Footnote(text: "Chance of at least one calm moment in each hour, from the last 8 weeks on the same weekday and hour.")
        }
    }

    // MARK: (d) AI weekly report

    @ViewBuilder private var reportCard: some View {
        EbbCard(title: "This week's report") {
            if let insight {
                let r = insight.report
                if !r.headline.isEmpty {
                    Text(r.headline).font(.title3).foregroundStyle(Ebb.ink)
                }
                section("Patterns", r.patterns)
                section("What helps", r.whatHelps)
                section("Try this", r.suggestions)
                if !r.riskWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Times to watch").font(.subheadline.weight(.semibold)).foregroundStyle(Ebb.ink)
                        ForEach(r.riskWindows, id: \.self) { w in
                            InsetPanel {
                                Text("\(w.day) \(w.from)–\(w.to)").font(.subheadline.weight(.semibold)).foregroundStyle(Ebb.ink)
                                if let why = w.why, !why.isEmpty {
                                    Text(why).font(.footnote).foregroundStyle(Ebb.inkSoft)
                                }
                            }
                        }
                    }
                }
                Footnote(text: "Written \(insight.createdAt.formatted(date: .abbreviated, time: .shortened)) by AI from calm moments, ratings and notes. No names are sent. Check it against what you see.")
            } else {
                Text("No report yet. Ebb can write one from this week's calm moments, ratings and notes.")
                    .foregroundStyle(Ebb.inkSoft)
            }
            Button(writing ? "Writing..." : "Write this week's report") { Task { await write() } }
                .buttonStyle(.ebbPrimary)
                .disabled(writing)
            if writing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("This takes about half a minute.").font(.footnote).foregroundStyle(Ebb.inkSoft)
                }
            }
        }
        if let writeError {
            ErrorCard(headline: "The report could not be written", message: writeError) {
                Task { await write() }
            }
        }
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Ebb.ink)
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Ebb.teal).frame(width: 5, height: 5).padding(.top, 7)
                            Text(item).font(.subheadline).foregroundStyle(Ebb.ink)
                        }
                    }
                }
            }
        }
    }

    private func write() async {
        writing = true
        writeError = nil
        defer { writing = false }
        do {
            if let row = try await model.writeWeeklyInsight(for: child) { insight = row }
        } catch {
            writeError = error.localizedDescription
        }
    }

    // MARK: Formatting

    static func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(hour < 12 ? "a" : "p")"
    }

    static func hourRange(_ hour: Int) -> String {
        "\(hourLabel(hour))–\(hourLabel((hour + 1) % 24))".replacingOccurrences(of: "a", with: " am").replacingOccurrences(of: "p", with: " pm")
    }

    static func clockRange(_ start: Date) -> String {
        let end = start.addingTimeInterval(3600)
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}
