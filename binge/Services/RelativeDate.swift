import Foundation

// Compact relative-time formatter matching the web plugin's timeAgo()
// — "now / 3m / 4h / 2d / 1w / 3mo / 1y". Accepts either a full ISO
// 8601 instant (`"2024-…T…Z"`) or a Stash date string
// (`"YYYY-MM-DD"`). Empty / unparseable input returns "" so call
// sites can chain it through without explicit nil checks.
enum RelativeDate {
    static func relative(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        // Two-parser fallback: full ISO 8601 first, then date-only.
        // Stash returns ISO for created_at but a bare YYYY-MM-DD
        // for the manual `date` field.
        let date: Date?
        if iso.count > 10 {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            date = f.date(from: iso)
        }
        guard let then = date else { return "" }
        let diff = Date().timeIntervalSince(then)
        if diff < 60 { return "now" }
        let m = Int(diff / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 7 { return "\(d)d" }
        let w = d / 7
        if w < 5 { return "\(w)w" }
        let mo = d / 30
        if mo < 12 { return "\(mo)mo" }
        return "\(d / 365)y"
    }
}
