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
