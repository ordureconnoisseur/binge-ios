import Foundation

// Fetch Stash's configured rating precision so binge's preview
// formula snaps to the same increments the plugin's hook will
// use server-side. Direct port of src/rating/precision.ts.
//
// configuration.ui.ratingSystemOptions:
//   type:
//     STARS:
//       starPrecision:
//         FULL    → 20 (whole stars only)
//         HALF    → 10
//         QUARTER → 5
//         TENTH   → 1
//     DECIMAL: 1 (any value 0–100)
//
// Cached for the session — the user's choice doesn't change often.

@MainActor
final class RatingPrecisionLoader {
    static let shared = RatingPrecisionLoader()
    private init() {}

    private var cached: Int?
    private var fetchTask: Task<Int, Never>?

    /// Returns the 0–100 rating granularity step. Default 20
    /// (whole-star precision) on any failure path.
    func load(baseURL: String, apiKey: String) async -> Int {
        if let cached { return cached }
        if let existing = fetchTask { return await existing.value }
        let task = Task<Int, Never> { [weak self] in
            let result = await Self.fetchPrecision(
                baseURL: baseURL, apiKey: apiKey
            )
            self?.cache(result)
            return result
        }
        fetchTask = task
        return await task.value
    }

    func invalidate() {
        cached = nil
        fetchTask = nil
    }

    private func cache(_ value: Int) {
        cached = value
    }

    private static func fetchPrecision(
        baseURL: String, apiKey: String
    ) async -> Int {
        let trimmed = baseURL.trimmingCharacters(
            in: .init(charactersIn: "/ \n\r\t")
        )
        guard let url = URL(string: "\(trimmed)/graphql") else {
            return 20
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.addValue(apiKey, forHTTPHeaderField: "ApiKey")
        }
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["query": "query { configuration { ui } }"]
        )
        do {
            let (data, resp) = try await CredentialSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return 20
            }
            guard
                let json =
                    try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let dataObj = json["data"] as? [String: Any],
                let config = dataObj["configuration"] as? [String: Any],
                let ui = config["ui"] as? [String: Any]
            else {
                return 20
            }
            let opts = ui["ratingSystemOptions"] as? [String: Any]
            // Upper-cased before comparing. Stash stores these
            // lowercase - this box has starPrecision "tenth" and type
            // "stars" - so every case below was dead and the default of
            // 20 was the only reachable answer, while the plugin's
            // Python hook upper-cases and gets 1. The preview was
            // computed at the wrong precision on every rated scene, and
            // since the modal shows the preview whenever anything is
            // scored, the authoritative rating it had just fetched was
            // never displayed.
            if (opts?["type"] as? String)?.uppercased() == "DECIMAL" {
                return 1
            }
            switch (opts?["starPrecision"] as? String)?.uppercased() {
            case "FULL": return 20
            case "HALF": return 10
            case "QUARTER": return 5
            case "TENTH": return 1
            default: return 20
            }
        } catch {
            return 20
        }
    }
}
