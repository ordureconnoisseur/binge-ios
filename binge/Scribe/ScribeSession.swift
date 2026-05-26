import Foundation

// Resumable interview/result state — same key format as web's
// session.ts so opening the same scene in binge-web and
// binge-ios picks up the same transcript when running against
// one Stash. Stored as JSON-encoded data on UserDefaults
// (mirrors localStorage on web).
//
// Key shape: `stashScribe.session.<kind>.<id>`
//   - kind: "scene" | "performer"
//   - id: Stash entity id
enum ScribeSessionStore {
    static func key(for ref: SubjectRef) -> String {
        return "stashScribe.session.\(ref.kind).\(ref.rawId)"
    }

    static func load(_ key: String) -> ScribeSessionState? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                ScribeSessionState.self, from: data
            )
        } catch {
            // Stale schema or hand-edited entry — drop quietly so
            // the next save replaces it.
            return nil
        }
    }

    static func save(_ key: String, state: ScribeSessionState) {
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("[binge] scribe: session save failed: \(error)")
        }
    }

    static func clear(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
