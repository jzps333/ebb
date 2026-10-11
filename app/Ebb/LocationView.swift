import MapKit
import SwiftUI

/// Opt-in GPS from the watch: the parent's consent switch, then a map of the
/// trail and where calm moments started. Teachers see it in school hours only.
struct LocationView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var points: [LocationPoint] = []
    @State private var range = "today"
    @State private var confirmingOff = false
    @State private var saving = false
    @State private var loaded = false

    private var isTeacher: Bool { model.profile?.isTeacher == true }
    private var settings: ChildSettings? { model.childSettings[child.id] }
    private var enabled: Bool { settings?.gpsEnabled == true }
    private var trail: [CLLocationCoordinate2D] {
        points.filter { $0.kind == "trail" }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }
    private var calmPins: [LocationPoint] { points.filter { $0.kind == "calm" } }

    var body: some View {
        EbbScreen {
            PageTitle(text: "Location", subtitle: "Where \(child.nickname)'s watch has been, only if the parent turns it on.")

            if isTeacher {
                teacherContent
            } else {
                consentCard
                if enabled { mapCard }
            }
        }
        .ebbNavigation("\(child.nickname)'s location")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: range) { Task { await loadPoints() } }
        .confirmationDialog("Turn off location?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn off and erase", role: .destructive) { Task { await setGPS(false) } }
            Button("Keep it on", role: .cancel) {}
        } message: {
            Text("The watch stops sending its position, and every point already collected for \(child.nickname) is erased right away.")
        }
    }

    private func reload() async {
        await model.refreshSettings()
        await loadPoints()
        loaded = true
    }

    private func loadPoints() async {
        guard enabled, !isTeacher || Self.isSchoolHours(Date()) else { points = []; return }
        let since = range == "today"
            ? Calendar.current.startOfDay(for: Date())
            : Date().addingTimeInterval(-7 * 24 * 3600)
        points = await model.locations(for: child, since: since)
    }

    private func setGPS(_ on: Bool) async {
        saving = true
        await model.setGPS(for: child, enabled: on)
        saving = false
        await loadPoints()
    }

    // MARK: Parent

    private var consentCard: some View {
        EbbCard(title: "Location sharing") {
            Text("When this is on, the watch records where it is every 5 minutes and where each calm moment starts. Points are kept for 30 days.")
                .foregroundStyle(Ebb.ink)
            Text("You always see them. \(child.nickname)'s linked teachers see only points from school days, 8am–3pm, and only during those hours.")
                .font(.subheadline).foregroundStyle(Ebb.inkSoft)
            Toggle(isOn: Binding(
                get: { enabled },
                set: { on in
                    if on { Task { await setGPS(true) } } else { confirmingOff = true }
                }
            )) {
                Text("Share the watch's location").foregroundStyle(Ebb.ink)
            }
            .tint(Ebb.teal)
            .disabled(settings == nil || saving)
            if let consent = settings?.gpsConsentAt, enabled {
                Footnote(text: "You agreed on \(consent.formatted(date: .abbreviated, time: .shortened)). Turning it off erases every collected point.")
            } else {
                Footnote(text: "Turning it on records your consent with today's date. You can turn it off any time; collected points are erased then.")
            }
        }
    }

    // MARK: Teacher

    @ViewBuilder private var teacherContent: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity)
        } else if !enabled {
            EbbCard { Text("Location is off for \(child.nickname). Only the parent can turn it on.").foregroundStyle(Ebb.inkSoft) }
        } else if !Self.isSchoolHours(Date()) {
            EbbCard(title: "Outside school hours") {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Ebb.teal)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(Ebb.previewBlue, in: RoundedRectangle(cornerRadius: 12))
                Text("The map opens on school days between 8am and 3pm.").foregroundStyle(Ebb.ink)
            }
        } else {
            mapCard
        }
        Footnote(text: "Visible on school days 8am–3pm only")
    }

    // MARK: Map

    private var mapCard: some View {
        EbbCard(title: "Map", padding: 12) {
            SegmentChoice(options: [("today", "Today"), ("week", "Last 7 days")], selection: $range)
            if points.isEmpty {
                Text("No points yet. The watch sends one every 5 minutes when it has a GPS fix.")
                    .font(.subheadline).foregroundStyle(Ebb.inkSoft)
                    .padding(.vertical, 8)
            } else {
                Map(initialPosition: .automatic) {
                    if trail.count > 1 {
                        MapPolyline(coordinates: trail)
                            .stroke(Ebb.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    if let last = points.last(where: { $0.kind == "trail" }) {
                        Annotation("Latest", coordinate: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lng)) {
                            Circle().fill(Ebb.teal).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    ForEach(calmPins) { p in
                        Marker("Calm \(p.at.formatted(date: .omitted, time: .shortened))", systemImage: "water.waves",
                               coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng))
                            .tint(Ebb.tealBottom)
                    }
                }
                .id(points.count)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ebb.cardBorder, lineWidth: 1))
                HStack(spacing: 14) {
                    Label("Trail", systemImage: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Ebb.teal)
                    Label("Calm moment", systemImage: "water.waves").foregroundStyle(Ebb.tealBottom)
                }
                .font(.caption)
                if let last = points.last {
                    Footnote(text: "\(points.count) points · latest \(last.at.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
    }

    /// Monday–Friday, 08:00–15:00 in the school's time zone (matches the server's RLS).
    static func isSchoolHours(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Config.schoolTimeZone
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday
        let hour = calendar.component(.hour, from: date)
        return (2 ... 6).contains(weekday) && hour >= 8 && hour < 15
    }
}
