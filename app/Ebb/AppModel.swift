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
    var isLoading = false
    var profile: Profile?
    var children: [Child] = []
    var devices: [UUID: Device] = [:]        // child id -> that child's current watch
    var today: [UUID: DaySummary] = [:]      // child id -> today's summary
    var calmProfiles: [UUID: CalmProfileRow] = [:]  // child id -> newest profile (draft or approved)
    var banner: String?                      // live "calm started" alert
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
        }
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
            .select("id, child_id, last_seen_at, battery_pct, calm_active")
            .not("child_id", operator: .is, value: "null")
            .order("last_seen_at", ascending: false, nullsFirst: false)
            .execute()
            .value
        // Rows come newest first, so the first one per child is its current watch.
        var byChild: [UUID: Device] = [:]
        for device in rows {
            if let child = device.childId, byChild[child] == nil { byChild[child] = device }
        }
        devices = byChild
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
                for await _ in changedEvents { try? await self?.reloadToday() }
            },
            Task { [weak self] in
                for await _ in changedDevices { try? await self?.reloadDevices() }
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

        banner = message
        Notifier.post(title: "Calm mode started", body: message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.banner == message { self?.banner = nil }
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
