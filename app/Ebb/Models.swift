import Foundation

struct Profile: Decodable {
    let id: UUID
    let displayName: String?
    let role: String

    var isTeacher: Bool { role == "teacher" }

    enum CodingKeys: String, CodingKey {
        case id, role
        case displayName = "display_name"
    }
}

struct Child: Decodable, Identifiable, Hashable {
    let id: UUID
    let ownerId: UUID
    let nickname: String
    let ageBand: String

    enum CodingKeys: String, CodingKey {
        case id, nickname
        case ownerId = "owner_id"
        case ageBand = "age_band"
    }
}

struct Device: Decodable, Identifiable {
    let id: UUID
    let childId: UUID?
    let lastSeenAt: Date?
    let batteryPct: Int?
    let calmActive: Bool
    /// Live agitation from the watch (1.0 = the auto-start line) and its response tier.
    let agitation: Double?
    let agitationAt: Date?
    let tier: Int?

    /// 0 settled, 1 rising (wrist cue), 2 calm mode, 3 needs an adult.
    var currentTier: Int { tier ?? 0 }

    /// The watch polls every 3 s, so 30 s of silence means it is off or offline.
    var isOnline: Bool {
        guard let lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeenAt) < 30
    }

    enum CodingKeys: String, CodingKey {
        case id
        case childId = "child_id"
        case lastSeenAt = "last_seen_at"
        case batteryPct = "battery_pct"
        case calmActive = "calm_active"
        case agitation, tier
        case agitationAt = "agitation_at"
    }

    static func tierLabel(_ tier: Int) -> String {
        switch tier {
        case 1: return "Rising – wrist cue"
        case 2: return "Calm mode"
        case 3: return "Needs an adult"
        default: return "Settled"
        }
    }
}

/// One row of the child_day_summary view.
struct DaySummary: Decodable {
    let childId: UUID
    let day: String
    let sessions: Int
    let calmMinutes: Double
    let byTeacher: Int
    let byChildTap: Int
    let byMotion: Int
    let byNoise: Int
    let helpedYes: Int
    let helpedNo: Int

    enum CodingKeys: String, CodingKey {
        case day, sessions
        case childId = "child_id"
        case calmMinutes = "calm_minutes"
        case byTeacher = "by_teacher"
        case byChildTap = "by_child_tap"
        case byMotion = "by_motion"
        case byNoise = "by_noise"
        case helpedYes = "helped_yes"
        case helpedNo = "helped_no"
    }
}

struct NewCommand: Encodable {
    let device_id: UUID
    let child_id: UUID
    let type: String  // "start_calm" or "stop_calm"
}

struct NewChild: Encodable {
    let nickname: String
    let age_band: String
    let consent_at: Date
}

/// What pair_claim_watch / pair_join_watch return.
struct PairResult: Decodable {
    let ok: Bool
    let nickname: String?
    let error: String?
}

enum AgeBand: String, CaseIterable, Identifiable {
    case fourToFive = "4-5", sixToEight = "6-8", nineToEleven = "9-11", twelveToFourteen = "12-14", fifteenToEighteen = "15-18"
    var id: String { rawValue }
}

// MARK: Calm profile (what the watch runs)

struct CalmProfile: Codable, Hashable {
    struct AutoTriggers: Codable, Hashable { let motion: Bool; let noise: Bool }

    let theme: String
    let colors: [String]
    let breathPattern: String
    let vibration: String
    let sound: String
    let volume: String
    let autoTriggers: AutoTriggers
    let noiseSensitivity: String
    let calmMessage: String
    let parentSummary: String

    enum CodingKeys: String, CodingKey {
        case theme, colors, vibration, sound, volume
        case breathPattern = "breath_pattern"
        case autoTriggers = "auto_triggers"
        case noiseSensitivity = "noise_sensitivity"
        case calmMessage = "calm_message"
        case parentSummary = "parent_summary"
    }
}

struct CalmProfileRow: Decodable, Identifiable, Hashable {
    let id: UUID
    let childId: UUID?
    let version: Int
    let status: String  // "draft" or "approved"
    let profile: CalmProfile

    var isApproved: Bool { status == "approved" }

    enum CodingKeys: String, CodingKey {
        case id, version, status, profile
        case childId = "child_id"
    }
}

/// The parent's answers, stored as jsonb in assessments.answers and sent to
/// generate-profile. Keys match docs/assessment-questions.md.
struct AssessmentAnswers: Codable {
    var triggers: Set<String> = []
    var soundSensitivity = "a_little"
    var touch = "depends"
    var vibration = "not_sure"
    var colors: Set<String> = []
    var favoriteThings: Set<String> = []
    var soundsLiked: Set<String> = []
    var canFollowBreathing = "with_help"
    var whatHelps = ""
    var upsetSigns: Set<String> = []
    var neverDo = ""

    enum CodingKeys: String, CodingKey {
        case triggers, touch, vibration, colors
        case soundSensitivity = "sound_sensitivity"
        case favoriteThings = "favorite_things"
        case soundsLiked = "sounds_liked"
        case canFollowBreathing = "can_follow_breathing"
        case whatHelps = "what_helps"
        case upsetSigns = "upset_signs"
        case neverDo = "never_do"
    }
}

struct NewAssessment: Encodable {
    let child_id: UUID
    let answers: AssessmentAnswers
}

// MARK: Parent voice

struct VoiceClip: Decodable, Identifiable, Hashable {
    let id: UUID
    let phrase: String
    var status: String  // "draft" or "approved"
    let url: URL?

    var isApproved: Bool { status == "approved" }
}

struct VoiceState: Decodable {
    let hasVoice: Bool
    let voiceKind: String?  // "stock" (calm AI voice) or "clone" (parent's own)
    let clips: [VoiceClip]

    var isStock: Bool { voiceKind == "stock" }

    enum CodingKeys: String, CodingKey {
        case clips
        case hasVoice = "has_voice"
        case voiceKind = "voice_kind"
    }
}

// MARK: Weekly scenes

struct CalmScene: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let video: String
    let sound: String

    /// The looping GIF in the public scene-media bucket.
    var previewURL: URL {
        Config.supabaseURL.appendingPathComponent("storage/v1/object/public/scene-media/\(video).gif")
    }
}

struct SceneSetItem: Decodable, Hashable {
    let position: Int
    let isAnchor: Bool
    let sceneId: String

    enum CodingKeys: String, CodingKey {
        case position
        case isAnchor = "is_anchor"
        case sceneId = "scene_id"
    }
}

struct SceneSet: Decodable, Identifiable {
    let id: UUID
    let weekStart: String
    var status: String
    var items: [SceneSetItem]

    var isApproved: Bool { status == "approved" }

    enum CodingKeys: String, CodingKey {
        case id, status
        case weekStart = "week_start"
        case items = "scene_set_items"
    }
}

/// One finished calm session, with its scene and the teacher's rating.
struct CalmMoment: Decodable, Identifiable, Hashable {
    let id: UUID
    let childId: UUID
    let startedAt: Date
    let endedAt: Date?
    let trigger: String
    let sceneId: String?
    var helped: Bool?
    let helpedAt: Date?
    var falseAlarm: Bool?
    let agitationPeak: Double?
    let childFeeling: String?      // "better", "same" or "worse" (the watch's check-in)
    let agitationBefore: Double?
    let agitationAfter: Double?
    let recoverySeconds: Int?
    let tier: Int?

    /// Started by the watch on its own (movement or loud room).
    var isAutoStart: Bool { trigger == "motion" || trigger == "noise" }

    var minutes: Int {
        guard let endedAt else { return 0 }
        return max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
    }

    enum CodingKeys: String, CodingKey {
        case id, trigger, helped
        case childId = "child_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case sceneId = "scene_id"
        case helpedAt = "helped_at"
        case falseAlarm = "false_alarm"
        case agitationPeak = "agitation_peak"
        case childFeeling = "child_feeling"
        case agitationBefore = "agitation_before"
        case agitationAfter = "agitation_after"
        case recoverySeconds = "recovery_seconds"
        case tier
    }
}

// MARK: Journal

struct JournalNote: Decodable, Identifiable, Hashable {
    let id: UUID
    let eventId: UUID?
    let authorId: UUID
    var body: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body
        case eventId = "event_id"
        case authorId = "author_id"
        case updatedAt = "updated_at"
    }
}

// MARK: Adaptive Ebb (sensing, learning, insights, location)

/// What the watch follows: auto-start signals, learned sensitivity, GPS opt-in.
struct ChildSettings: Decodable, Hashable {
    let childId: UUID
    var autoMotion: Bool
    var autoNoise: Bool
    let motionK: Double
    let noiseK: Double
    var gpsEnabled: Bool
    var gpsConsentAt: Date?

    enum CodingKeys: String, CodingKey {
        case childId = "child_id"
        case autoMotion = "auto_motion"
        case autoNoise = "auto_noise"
        case motionK = "motion_k"
        case noiseK = "noise_k"
        case gpsEnabled = "gps_enabled"
        case gpsConsentAt = "gps_consent_at"
    }
}

/// One watch reading (about every 5 s while the watch is awake).
struct SensorSample: Decodable, Identifiable, Hashable {
    let id: Int
    let childId: UUID
    let at: Date
    let motion: Double?
    let noiseDb: Double?
    let motionZ: Double?
    let noiseZ: Double?
    let agitation: Double?

    enum CodingKeys: String, CodingKey {
        case id, at, motion, agitation
        case childId = "child_id"
        case noiseDb = "noise_db"
        case motionZ = "motion_z"
        case noiseZ = "noise_z"
    }
}

/// A change the learning made to motion_k / noise_k after a rating.
struct SensitivityChange: Decodable, Identifiable, Hashable {
    let id: Int
    let eventId: UUID?
    let at: Date
    let signal: String   // "motion" or "noise"
    let oldK: Double
    let newK: Double
    let reason: String   // "false alarm" or "helped"

    enum CodingKeys: String, CodingKey {
        case id, at, signal, reason
        case eventId = "event_id"
        case oldK = "old_k"
        case newK = "new_k"
    }
}

/// One scene's chance of helping (Beta posterior) in one time bucket.
struct SceneStat: Decodable, Hashable {
    let sceneId: String
    let title: String
    let bucket: String   // "all", "morning", "afternoon", "evening"
    let helped: Int
    let notHelped: Int
    let mean: Double
    let low: Double
    let high: Double

    var rated: Int { helped + notHelped }

    enum CodingKeys: String, CodingKey {
        case title, bucket, helped, mean, low, high
        case sceneId = "scene_id"
        case notHelped = "not_helped"
    }
}

/// child_pattern_stats: calm moments by weekday x hour (school time zone).
struct PatternStats: Decodable {
    struct Cell: Decodable, Hashable {
        let dow: Int     // ISO weekday, 1 = Monday
        let hour: Int
        let count: Int
    }

    let days: Int
    let total: Int
    let heatmap: [Cell]
    let avgMinutes: Double?
    let avgAgitationPeak: Double?
    let busiest: Cell?

    enum CodingKeys: String, CodingKey {
        case days, total, heatmap, busiest
        case avgMinutes = "avg_minutes"
        case avgAgitationPeak = "avg_agitation_peak"
    }
}

/// One hour of risk_forecast.
struct RiskHour: Decodable, Identifiable, Hashable {
    let hourStart: Date
    let expected: Double
    let risk: Double
    let level: String   // "low", "medium", "high"

    var id: Date { hourStart }

    enum CodingKeys: String, CodingKey {
        case expected, risk, level
        case hourStart = "hour_start"
    }
}

/// The AI weekly report (insights edge function -> weekly_insights).
struct InsightReport: Decodable, Hashable {
    struct RiskWindow: Decodable, Hashable {
        let day: String
        let from: String
        let to: String
        let why: String?
    }

    let headline: String
    let patterns: [String]
    let whatHelps: [String]
    let suggestions: [String]
    let riskWindows: [RiskWindow]

    enum CodingKeys: String, CodingKey {
        case headline, patterns, suggestions
        case whatHelps = "what_helps"
        case riskWindows = "risk_windows"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
        whatHelps = try c.decodeIfPresent([String].self, forKey: .whatHelps) ?? []
        suggestions = try c.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        riskWindows = try c.decodeIfPresent([RiskWindow].self, forKey: .riskWindows) ?? []
    }
}

struct WeeklyInsight: Decodable, Identifiable, Hashable {
    let id: UUID
    let childId: UUID
    let weekStart: String
    let report: InsightReport
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, report
        case childId = "child_id"
        case weekStart = "week_start"
        case createdAt = "created_at"
    }
}

/// Opt-in GPS: a trail point every few minutes, or where a calm moment started.
struct LocationPoint: Decodable, Identifiable, Hashable {
    let id: Int
    let eventId: UUID?
    let at: Date
    let lat: Double
    let lng: Double
    let accuracyM: Double?
    let kind: String   // "trail" or "calm"

    enum CodingKeys: String, CodingKey {
        case id, at, lat, lng, kind
        case eventId = "event_id"
        case accuracyM = "accuracy_m"
    }
}
