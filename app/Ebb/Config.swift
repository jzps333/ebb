import Foundation

// Public by design: the publishable key only lets a client talk to Supabase as
// "logged out" or as the signed-in user, and Row Level Security decides what
// each user can see or change. Never put a secret / service-role key here.
enum Config {
    static let supabaseURL = URL(string: "https://pchbznvjjmfcfjwrbmvj.supabase.co")!
    static let supabaseKey = "sb_publishable_qVnoz13SGD8kSMGXfyr-_A_z2iZPBB9"

    // child_day_summary groups days in this zone, so "today" must match it.
    static let schoolTimeZone = TimeZone(identifier: "America/New_York")!
}
