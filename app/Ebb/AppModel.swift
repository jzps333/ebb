import Foundation
import Observation
import Supabase
import UserNotifications

/// Everything the screens show, loaded from Supabase. Row Level Security on the
/// server decides which children each parent or teacher gets back.
@MainActor
@Observable
final class AppModel {
    let client = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseKey)

    var isSignedIn = false
    /// The "ebb Desktop" welcome screen, shown at launch and from the account menu.
    var showingDesktop = true
    var isLoading = false
    var profile: Profile?
    var children: [Child] = []
    var devices: [UUID: Device] = [:]        // child id -> that child's current watch
    var today: [UUID: DaySummary] = [:]      // child id -> today's summary
    var calmProfiles: [UUID: CalmProfileRow] = [:]  // child id -> newest profile (draft or approved)
    var banner: String?                      // live "calm started" alert
    var bannerIcon = "water.waves"           // escalation alerts use their own icon
    var childSettings: [UUID: ChildSettings] = [:]  // child id -> what the watch follows
    var samples: [UUID: [SensorSample]] = [:]       // child id -> last 10 min of readings (realtime)
    var errorMessage: String?
    var sendingCommandFor: UUID?             // child id while a Start/Stop is in flight

    private var liveChannel: RealtimeChannelV2?
    private var liveTasks: [Task<Void, Never>] = []

    // MARK: Session

    /// Follows sign-in / sign-out for the life of the app.
    func start() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .signedOut:
                let signedIn = session != nil && !(session?.isExpired ?? true)
                isSignedIn = signedIn
                if signedIn {
                    await reload()
                    await startLiveUpdates()
                } else {
                    await stopLiveUpdates()
                    profile = nil
                    children = []
                    devices = [:]
                    today = [:]
                    childSettings = [:]
                    samples = [:]
                }
            default:
                break
            }
        }
    }

    func signIn(email: String, password: String) async {
        await run { try await self.client.auth.signIn(email: email, password: password) }
    }

    /// Returns true when the account is ready; false means "check your email"
    /// (Supabase confirms email addresses before the first sign-in by default).
    func signUp(email: String, password: String, name: String, role: String) async -> Bool {
        var ready = false
        await run {
            let response = try await self.client.auth.signUp(
                email: email,
                password: password,
                data: ["role": .string(role), "display_name": .string(name)]
            )
            ready = response.session != nil
        }
        return ready
    }

    // MARK: Phone (codes go out by iMessage through Photon; see docs/photon-setup.md)

    /// Texts a sign-in code. For a new number, name and role become the profile.
    func sendPhoneCode(phone: String, name: String, role: String) async -> Bool {
        var sent = false
        await run {
            try await self.client.auth.signInWithOTP(
                phone: phone,
                data: ["role": .string(role), "display_name": .string(name)]
            )
            sent = true
        }
        return sent
    }

    func verifyPhoneCode(phone: String, code: String) async {
        await run { try await self.client.auth.verifyOTP(phone: phone, token: code, type: .sms) }
    }

    /// The signed-in user's confirmed phone, if any.
    var phone: String? {
        guard let p = client.auth.currentUser?.phone, !p.isEmpty else { return nil }
        return "+" + p.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
    }

    /// Adds a phone to an email account: texts a code, then confirmPhone.
    func addPhone(_ phone: String) async -> Bool {
        var sent = false
        await run {
            _ = try await self.client.auth.update(user: UserAttributes(phone: phone))
            sent = true
        }
        return sent
    }

    func confirmPhone(_ phone: String, code: String) async -> Bool {
        var ok = false
        await run {
            try await self.client.auth.verifyOTP(phone: phone, token: code, type: .phoneChange)
            _ = try await self.client.auth.refreshSession()
            ok = true
        }
        return ok
    }

    /// "(919) 555-0100" or "919 555 0100" -> "+19195550100"; keeps a leading +.
    static func e164(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return "+" + digits }
        return digits.count == 10 ? "+1" + digits : "+" + digits
    }

    func signOut() async {
        await run { try await self.client.auth.signOut() }
    }

    // MARK: Data

    func reload() async {
        guard let userId = client.auth.currentUser?.id else { return }
        isLoading = true
        defer { isLoading = false }
        await run {
            self.profile = try await self.client.from("profiles")
                .select("id, display_name, role")
                .eq("id", value: userId)
                .single()
                .execute()
                .value

            self.children = try await self.client.from("children")
                .select("id, owner_id, nickname, age_band")
                .order("nickname")
                .execute()
                .value

            try await self.reloadDevices()
            try await self.reloadToday()
            try await self.reloadCalmProfiles()
            try await self.reloadUnrated()
            try await self.reloadChildSettings()
        }
        await loadSceneLibrary()
    }

    private func reloadCalmProfiles() async throws {
        let rows: [CalmProfileRow] = try await client.from("calm_profiles")
            .select("id, child_id, version, status, profile")
            .order("version", ascending: false)
            .execute()
            .value
        var newest: [UUID: CalmProfileRow] = [:]
        for row in rows {
            if let child = row.childId, newest[child] == nil { newest[child] = row }
        }
        calmProfiles = newest
    }

    private func reloadDevices() async throws {
        let rows: [Device] = try await client.from("devices")
            .select("id, child_id, last_seen_at, battery_pct, calm_active, agitation, agitation_at, tier")
            .not("child_id", operator: .is, value: "null")
            .order("last_seen_at", ascending: false, nullsFirst: false)
            .execute()
            .value
        // Rows come newest first, so the first one per child is its current watch.
        var byChild: [UUID: Device] = [:]
        for device in rows {
            if let child = device.childId, byChild[child] == nil { byChild[child] = device }
        }
        let previous = devices
        devices = byChild
        for (childId, device) in byChild {
            guard let before = previous[childId], before.id == device.id else { continue }
            tierChanged(childId: childId, from: before.currentTier, to: device.currentTier)
        }
    }

    private func reloadToday() async throws {
        let rows: [DaySummary] = try await client.from("child_day_summary")
            .select()
            .eq("day", value: Self.todayString())
            .execute()
            .value
        today = Dictionary(rows.map { ($0.childId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = Config.schoolTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: Start / Stop calm

    /// Inserts a command; the watch picks it up on its next 3-second poll.
    func send(_ type: String, to child: Child) async {
        guard let device = devices[child.id] else {
            errorMessage = "\(child.nickname) has no paired watch yet."
            return
        }
        sendingCommandFor = child.id
        defer { sendingCommandFor = nil }
        await run {
            try await self.client.from("commands")
                .insert(NewCommand(device_id: device.id, child_id: child.id, type: type))
                .execute()
        }
    }

    // MARK: Assessment and calm profile

    /// Saves the answers, then asks generate-profile (Gemini) for a draft profile.
    func makeCalmProfile(for child: Child, answers: AssessmentAnswers) async -> CalmProfileRow? {
        struct Saved: Decodable { let id: UUID }
        struct Request: Encodable { let assessment_id: UUID }
        do {
            let saved: Saved = try await client.from("assessments")
                .insert(NewAssessment(child_id: child.id, answers: answers))
                .select("id")
                .single()
                .execute()
                .value
            let row: CalmProfileRow = try await client.functions.invoke(
                "generate-profile",
                options: FunctionInvokeOptions(body: Request(assessment_id: saved.id))
            )
            calmProfiles[child.id] = row
            return row
        } catch let FunctionsError.httpError(_, data) {
            struct Message: Decodable { let error: String }
            errorMessage = (try? JSONDecoder().decode(Message.self, from: data))?.error ?? "Could not make the profile."
        } catch {
            errorMessage = error.localizedDescription
        }
        return nil
    }

    /// Approving makes it the profile the watch downloads on its next poll.
    func approve(_ row: CalmProfileRow) async {
        struct Approval: Encodable { let status: String; let approved_at: Date }
        await run {
            try await self.client.from("calm_profiles")
                .update(Approval(status: "approved", approved_at: Date()))
                .eq("id", value: row.id)
                .execute()
            try await self.reloadCalmProfiles()
        }
    }

    // MARK: Weekly scenes

    var sceneLibrary: [CalmScene] = []
    var latestMoment: [UUID: CalmMoment] = [:]   // child id -> latest finished calm moment

    func loadSceneLibrary() async {
        guard sceneLibrary.isEmpty else { return }
        await run {
            self.sceneLibrary = try await self.client.from("scenes")
                .select("id, title, video, sound")
                .order("id")
                .execute()
                .value
        }
    }

    /// The newest set for the child (this week's, or next week's draft).
    func sceneSet(for child: Child) async -> SceneSet? {
        var result: SceneSet?
        await run {
            let sets: [SceneSet] = try await self.client.from("scene_sets")
                .select("id, week_start, status, scene_set_items(position, is_anchor, scene_id)")
                .eq("child_id", value: child.id)
                .order("week_start", ascending: false)
                .limit(1)
                .execute()
                .value
            result = sets.first.map { set in
                var sorted = set
                sorted.items.sort { $0.position < $1.position }
                return sorted
            }
        }
        return result
    }

    /// Builds this week's set (or next week's, once this week's is approved).
    func makeSceneSet(for child: Child) async -> SceneSet? {
        struct Params: Encodable { let p_child_id: UUID }
        await run {
            _ = try await self.client.rpc("make_scene_set", params: Params(p_child_id: child.id)).execute()
        }
        return await sceneSet(for: child)
    }

    func approve(_ set: SceneSet) async {
        struct Approval: Encodable { let status: String; let approved_at: Date }
        await run {
            try await self.client.from("scene_sets")
                .update(Approval(status: "approved", approved_at: Date()))
                .eq("id", value: set.id)
                .execute()
        }
    }

    func swap(_ set: SceneSet, position: Int, to scene: CalmScene) async {
        struct Change: Encodable { let scene_id: String }
        await run {
            try await self.client.from("scene_set_items")
                .update(Change(scene_id: scene.id))
                .eq("set_id", value: set.id)
                .eq("position", value: position)
                .execute()
        }
    }

    // MARK: Did it help? (rated by the teacher)

    private static let momentColumns = "id, child_id, started_at, ended_at, trigger, scene_id, helped, helped_at, "
        + "false_alarm, agitation_peak, child_feeling, agitation_before, agitation_after, recovery_seconds, tier"

    /// The latest finished calm moment per child, rated or not. The card only
    /// ever asks about this one, so rating it never surfaces older moments.
    func reloadUnrated() async throws {
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        let rows: [CalmMoment] = try await client.from("events")
            .select(Self.momentColumns)
            .not("ended_at", operator: .is, value: "null")
            .gte("started_at", value: since)
            .order("started_at", ascending: false)
            .limit(50)
            .execute()
            .value
        var latest: [UUID: CalmMoment] = [:]
        for e in rows where latest[e.childId] == nil { latest[e.childId] = e }
        latestMoment = latest
    }

    /// Today's finished calm moments for one child, newest first.
    func moments(for child: Child) async -> [CalmMoment] {
        var rows: [CalmMoment] = []
        let startOfDay = Calendar.current.startOfDay(for: Date())
        await run {
            rows = try await self.client.from("events")
                .select(Self.momentColumns)
                .eq("child_id", value: child.id)
                .not("ended_at", operator: .is, value: "null")
                .gte("started_at", value: startOfDay)
                .order("started_at", ascending: false)
                .execute()
                .value
        }
        return rows
    }

    /// Saved with who rated it and when (a database trigger stamps both);
    /// feeds the weekly scene picker.
    func rate(_ moment: CalmMoment, helped: Bool) async {
        struct Rating: Encodable { let helped: Bool }
        await run {
            try await self.client.from("events")
                .update(Rating(helped: helped))
                .eq("id", value: moment.id)
                .execute()
            try await self.reloadUnrated()
            try await self.reloadToday()
        }
    }

    /// An auto-start that should not have happened. The server makes that
    /// signal less sensitive (see sensitivity_log) and leaves it out of the scene picker.
    func markFalseAlarm(_ moment: CalmMoment) async {
        struct Rating: Encodable { let false_alarm: Bool }
        await run {
            try await self.client.from("events")
                .update(Rating(false_alarm: true))
                .eq("id", value: moment.id)
                .execute()
            try await self.reloadUnrated()
            try await self.reloadChildSettings()
        }
    }

    /// "Agitation 0.92 → 0.31 · settled in 48 s · Sam felt better 🙂", or nil.
    static func outcome(_ m: CalmMoment, name: String) -> String? {
        var parts: [String] = []
        if let before = m.agitationBefore, let after = m.agitationAfter {
            parts.append(String(format: "Agitation %.2f → %.2f", before, after))
        } else if let peak = m.agitationPeak {
            parts.append(String(format: "Peak agitation %.2f", peak))
        }
        if let s = m.recoverySeconds {
            parts.append("settled in " + (s < 90 ? "\(s) s" : "\(Int((Double(s) / 60).rounded())) min"))
        }
        switch m.childFeeling {
        case "better": parts.append("\(name) felt better 🙂")
        case "same": parts.append("\(name) felt the same 😐")
        case "worse": parts.append("\(name) felt worse 🙁")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Adaptive sensing (live agitation, auto-start, learned sensitivity)

    private func reloadChildSettings() async throws {
        let rows: [ChildSettings] = try await client.from("child_settings")
            .select("child_id, auto_motion, auto_noise, motion_k, noise_k, gps_enabled, gps_consent_at")
            .execute()
            .value
        childSettings = Dictionary(rows.map { ($0.childId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func refreshSettings() async {
        await run { try await self.reloadChildSettings() }
    }

    /// Parent only (RLS); the watch picks the change up on its next poll.
    func setAutoStart(for child: Child, motion: Bool, noise: Bool) async {
        struct Change: Encodable { let auto_motion: Bool; let auto_noise: Bool }
        await run {
            try await self.client.from("child_settings")
                .update(Change(auto_motion: motion, auto_noise: noise))
                .eq("child_id", value: child.id)
                .execute()
            try await self.reloadChildSettings()
        }
    }

    /// Parent only. Turning GPS on records consent now; turning it off makes
    /// the server erase every point collected for this child.
    func setGPS(for child: Child, enabled: Bool) async {
        struct On: Encodable { let gps_enabled: Bool; let gps_consent_at: Date }
        struct Off: Encodable { let gps_enabled: Bool }
        await run {
            if enabled {
                try await self.client.from("child_settings")
                    .update(On(gps_enabled: true, gps_consent_at: Date()))
                    .eq("child_id", value: child.id)
                    .execute()
            } else {
                try await self.client.from("child_settings")
                    .update(Off(gps_enabled: false))
                    .eq("child_id", value: child.id)
                    .execute()
            }
            try await self.reloadChildSettings()
        }
    }

    /// The last 10 minutes of readings; realtime inserts keep it going.
    func loadSamples(for child: Child) async {
        await run {
            let rows: [SensorSample] = try await self.client.from("sensor_samples")
                .select("id, child_id, at, motion, noise_db, motion_z, noise_z, agitation")
                .eq("child_id", value: child.id)
                .gte("at", value: Date().addingTimeInterval(-Self.liveWindow))
                .order("at")
                .limit(500)
                .execute()
                .value
            self.samples[child.id] = rows
        }
    }

    static let liveWindow: TimeInterval = 10 * 60

    private func sampleArrived(_ sample: SensorSample) {
        var rows = samples[sample.childId] ?? []
        guard !rows.contains(where: { $0.id == sample.id }) else { return }
        rows.append(sample)
        if rows.count > 1 && rows[rows.count - 2].at > sample.at { rows.sort { $0.at < $1.at } }
        let cutoff = Date().addingTimeInterval(-Self.liveWindow)
        rows.removeAll { $0.at < cutoff }
        samples[sample.childId] = rows
    }

    /// What the learning changed, newest first.
    func sensitivityLog(for child: Child) async -> [SensitivityChange] {
        var rows: [SensitivityChange] = []
        await run {
            rows = try await self.client.from("sensitivity_log")
                .select("id, event_id, at, signal, old_k, new_k, reason")
                .eq("child_id", value: child.id)
                .order("at", ascending: false)
                .limit(20)
                .execute()
                .value
        }
        return rows
    }

    // MARK: Patterns, scene stats, risk forecast, weekly report

    func patternStats(for child: Child, days: Int = 28) async -> PatternStats? {
        struct Params: Encodable { let p_child_id: UUID; let p_days: Int }
        var result: PatternStats?
        await run {
            result = try await self.client.rpc("child_pattern_stats", params: Params(p_child_id: child.id, p_days: days))
                .execute()
                .value
        }
        return result
    }

    func sceneStats(for child: Child) async -> [SceneStat] {
        struct Params: Encodable { let p_child_id: UUID }
        var rows: [SceneStat] = []
        await run {
            rows = try await self.client.rpc("scene_stats", params: Params(p_child_id: child.id)).execute().value
        }
        return rows
    }

    func riskForecast(for child: Child, hours: Int = 8) async -> [RiskHour] {
        struct Params: Encodable { let p_child_id: UUID; let p_hours: Int }
        var rows: [RiskHour] = []
        await run {
            rows = try await self.client.rpc("risk_forecast", params: Params(p_child_id: child.id, p_hours: hours))
                .execute()
                .value
        }
        return rows
    }

    /// The newest AI weekly report, if one was written.
    func weeklyInsight(for child: Child) async -> WeeklyInsight? {
        var result: WeeklyInsight?
        await run {
            let rows: [WeeklyInsight] = try await self.client.from("weekly_insights")
                .select("id, child_id, week_start, report, created_at")
                .eq("child_id", value: child.id)
                .order("week_start", ascending: false)
                .limit(1)
                .execute()
                .value
            result = rows.first
        }
        return result
    }

    /// Asks the insights function (Gemini) to write this week's report, then
    /// reads the saved row back. Throws a readable message on failure.
    func writeWeeklyInsight(for child: Child) async throws -> WeeklyInsight? {
        struct Request: Encodable { let child_id: UUID }
        do {
            try await client.functions.invoke("insights", options: FunctionInvokeOptions(body: Request(child_id: child.id)))
        } catch let FunctionsError.httpError(_, data) {
            throw EbbError((try? JSONDecoder().decode(FunctionError.self, from: data))?.error ?? "Could not write the report.")
        }
        let rows: [WeeklyInsight] = try await client.from("weekly_insights")
            .select("id, child_id, week_start, report, created_at")
            .eq("child_id", value: child.id)
            .order("week_start", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: Location (opt-in GPS)

    /// Points since `since`, oldest first. RLS hides them from teachers outside school hours.
    func locations(for child: Child, since: Date) async -> [LocationPoint] {
        var rows: [LocationPoint] = []
        await run {
            rows = try await self.client.from("locations")
                .select("id, event_id, at, lat, lng, accuracy_m, kind")
                .eq("child_id", value: child.id)
                .gte("at", value: since)
                .order("at")
                .limit(1000)
                .execute()
                .value
        }
        return rows
    }

    // MARK: Journal notes on calm moments (teachers write, parents read)

    /// Notes for these calm moments, by event id.
    func notes(for moments: [CalmMoment]) async -> [UUID: JournalNote] {
        guard !moments.isEmpty else { return [:] }
        var byEvent: [UUID: JournalNote] = [:]
        await run {
            let rows: [JournalNote] = try await self.client.from("journal_entries")
                .select("id, event_id, author_id, body, updated_at")
                .eq("kind", value: "event")
                .in("event_id", values: moments.map(\.id))
                .order("updated_at", ascending: false)
                .execute()
                .value
            for r in rows { if let e = r.eventId, byEvent[e] == nil { byEvent[e] = r } }
        }
        return byEvent
    }

    /// Creates the teacher's note for a calm moment, or updates their existing one.
    func saveNote(_ text: String, for moment: CalmMoment, existing: JournalNote?) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        var ok = false
        await run {
            if let existing, existing.authorId == self.client.auth.currentUser?.id {
                struct Edit: Encodable { let body: String }
                try await self.client.from("journal_entries")
                    .update(Edit(body: body))
                    .eq("id", value: existing.id)
                    .execute()
            } else {
                struct New: Encodable { let child_id: UUID; let kind: String; let event_id: UUID; let body: String }
                try await self.client.from("journal_entries")
                    .insert(New(child_id: moment.childId, kind: "event", event_id: moment.id, body: body))
                    .execute()
            }
            ok = true
        }
        return ok
    }

    func sceneTitle(_ id: String?) -> String? {
        guard let id else { return nil }
        return sceneLibrary.first { $0.id == id }?.title
    }

    static func describe(_ m: CalmMoment, sceneTitle: String?) -> String {
        let time = m.startedAt.formatted(date: .omitted, time: .shortened)
        var parts = [time]
        if let sceneTitle { parts.append(sceneTitle) }
        parts.append("\(m.minutes) min")
        switch m.trigger {
        case "teacher": parts.append("started by teacher")
        case "child_tap": parts.append("child asked")
        case "motion": parts.append("movement")
        case "noise": parts.append("loud room")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Parent voice (ElevenLabs, via the voice function)

    func voiceState(for child: Child) async -> VoiceState? {
        await voiceCall {
            try await self.client.functions.invoke(
                "voice",
                options: FunctionInvokeOptions(method: .get, query: [
                    URLQueryItem(name: "action", value: "list"),
                    URLQueryItem(name: "child_id", value: child.id.uuidString),
                ])
            )
        }
    }

    /// Sends the recording straight to the voice function (it is not stored).
    func cloneVoice(recording: Data) async -> Bool {
        struct Ok: Decodable { let ok: Bool }
        let result: Ok? = await voiceCall {
            try await self.client.functions.invoke(
                "voice",
                options: FunctionInvokeOptions(
                    method: .post,
                    query: [URLQueryItem(name: "action", value: "clone"), URLQueryItem(name: "consent", value: "1")],
                    headers: ["Content-Type": "audio/mp4"],
                    body: recording
                )
            )
        }
        return result?.ok == true
    }

    /// A built-in calm female ElevenLabs voice instead of cloning (no recording).
    func useStockVoice() async -> Bool {
        struct Ok: Decodable { let ok: Bool }
        let result: Ok? = await voiceCall {
            try await self.client.functions.invoke(
                "voice",
                options: FunctionInvokeOptions(query: [URLQueryItem(name: "action", value: "use_stock")], body: [String: String]())
            )
        }
        return result?.ok == true
    }

    func makeVoiceClips(for child: Child, phrases: [String]) async -> [VoiceClip]? {
        struct Request: Encodable { let child_id: UUID; let phrases: [String] }
        struct Response: Decodable { let clips: [VoiceClip] }
        let response: Response? = await voiceCall {
            try await self.client.functions.invoke(
                "voice",
                options: FunctionInvokeOptions(
                    query: [URLQueryItem(name: "action", value: "generate")],
                    body: Request(child_id: child.id, phrases: phrases)
                )
            )
        }
        return response?.clips
    }

    /// Approved clips reach the watch within a few minutes.
    func setClip(_ clip: VoiceClip, approved: Bool) async -> Bool {
        struct Change: Encodable { let status: String; let approved_at: Date? }
        var ok = false
        await run {
            try await self.client.from("voice_clips")
                .update(Change(status: approved ? "approved" : "draft", approved_at: approved ? Date() : nil))
                .eq("id", value: clip.id)
                .execute()
            ok = true
        }
        return ok
    }

    func deleteVoice() async -> Bool {
        struct Ok: Decodable { let ok: Bool }
        let result: Ok? = await voiceCall {
            try await self.client.functions.invoke(
                "voice",
                options: FunctionInvokeOptions(query: [URLQueryItem(name: "action", value: "delete_voice")], body: [String: String]())
            )
        }
        return result?.ok == true
    }

    /// Runs a voice function call; its {"error": "..."} replies become errorMessage.
    private func voiceCall<T>(_ work: @escaping () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch let FunctionsError.httpError(_, data) {
            errorMessage = (try? JSONDecoder().decode(FunctionError.self, from: data))?.error ?? "Voice request failed."
        } catch {
            errorMessage = error.localizedDescription
        }
        return nil
    }

    // MARK: Children and pairing

    func addChild(nickname: String, ageBand: AgeBand) async -> Child? {
        var created: Child?
        await run {
            created = try await self.client.from("children")
                .insert(NewChild(nickname: nickname, age_band: ageBand.rawValue, consent_at: Date()))
                .select("id, owner_id, nickname, age_band")
                .single()
                .execute()
                .value
        }
        if created != nil { await reload() }
        return created
    }

    /// Parent: link the scanned watch to one of their children.
    func claimWatch(code: String, child: Child) async -> PairResult {
        struct Params: Encodable { let p_code: String; let p_child_id: UUID }
        return await pairCall("pair_claim_watch", Params(p_code: code, p_child_id: child.id))
    }

    /// Teacher: link themselves to the child whose watch they scanned.
    func joinWatch(code: String) async -> PairResult {
        struct Params: Encodable { let p_code: String }
        return await pairCall("pair_join_watch", Params(p_code: code))
    }

    private func pairCall(_ function: String, _ params: some Encodable) async -> PairResult {
        do {
            let result: PairResult = try await client.rpc(function, params: params).execute().value
            if result.ok { await reload() }
            return result
        } catch {
            return PairResult(ok: false, nickname: nil, error: error.localizedDescription)
        }
    }

    // MARK: Live alerts

    /// Realtime only delivers rows this user may see (RLS), so no filter is needed.
    private func startLiveUpdates() async {
        await stopLiveUpdates()
        let channel = client.channel("ebb-live")
        let newEvents = channel.postgresChange(InsertAction.self, schema: "public", table: "events")
        let changedEvents = channel.postgresChange(UpdateAction.self, schema: "public", table: "events")
        let changedDevices = channel.postgresChange(UpdateAction.self, schema: "public", table: "devices")
        let newSamples = channel.postgresChange(InsertAction.self, schema: "public", table: "sensor_samples")

        do {
            try await channel.subscribeWithError()
        } catch {
            errorMessage = "Live alerts are off: \(error.localizedDescription)"
            return
        }
        liveChannel = channel

        liveTasks = [
            Task { [weak self] in
                for await insert in newEvents { await self?.calmStarted(insert.record) }
            },
            Task { [weak self] in
                for await _ in changedEvents {
                    try? await self?.reloadToday()
                    try? await self?.reloadUnrated()
                }
            },
            Task { [weak self] in
                for await _ in changedDevices { try? await self?.reloadDevices() }
            },
            Task { [weak self] in
                for await insert in newSamples {
                    if let sample = try? insert.decodeRecord(as: SensorSample.self, decoder: AnyJSON.decoder) {
                        self?.sampleArrived(sample)
                    }
                }
            },
        ]
    }

    private func stopLiveUpdates() async {
        liveTasks.forEach { $0.cancel() }
        liveTasks = []
        if let liveChannel { await client.removeChannel(liveChannel) }
        liveChannel = nil
    }

    private func calmStarted(_ record: [String: AnyJSON]) async {
        try? await reloadToday()
        try? await reloadDevices()

        // Start reports arrive with no ended_at; an end-only report is not an alert.
        if let endedAt = record["ended_at"], endedAt != .null { return }
        let childId = record["child_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let name = children.first { $0.id == childId }?.nickname ?? "A student"
        let trigger = record["trigger"]?.stringValue ?? ""
        let message = "\(name) started calm mode" + Self.triggerSuffix(trigger)

        showBanner(message, icon: "water.waves")
        Notifier.post(title: "Calm mode started", body: message)
    }

    private func showBanner(_ message: String, icon: String, seconds: Double = 6) {
        banner = message
        bannerIcon = icon
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.banner == message { self?.banner = nil }
        }
    }

    /// Escalation from the watch's tier machine: 3 means calm mode has not
    /// settled the child after a minute, so an adult should go over; 1 is the
    /// softer early warning (the wrist breathing cue has started).
    private func tierChanged(childId: UUID, from old: Int, to new: Int) {
        guard new != old else { return }
        let name = children.first { $0.id == childId }?.nickname ?? "A student"
        if new == 3 {
            let message = "\(name) needs an adult"
            showBanner(message, icon: "exclamationmark.triangle", seconds: 12)
            Notifier.post(title: "Needs an adult", body: "\(message): calm mode has not settled things yet.")
        } else if new == 1 && old == 0 {
            let message = "\(name)'s agitation is rising"
            showBanner(message, icon: "wind")
            Notifier.post(title: "Agitation rising", body: "\(message). The watch has started a breathing cue.")
        }
    }

    static func triggerSuffix(_ trigger: String) -> String {
        switch trigger {
        case "teacher": return " (teacher)"
        case "child_tap": return " (tapped the watch)"
        case "motion": return " (movement detected)"
        case "noise": return " (loud room)"
        default: return ""
        }
    }

    // MARK: Helpers

    /// Runs a Supabase call and turns any failure into errorMessage.
    private func run(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The {"error": "..."} body our Edge Functions return on failure.
private struct FunctionError: Decodable { let error: String }

/// A failure with a message ready to show in an ErrorCard.
struct EbbError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Local notifications for calm alerts. They show while the app is open or
/// recently backgrounded; alerts with the app fully closed would need APNs push.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
