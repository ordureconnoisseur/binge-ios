import Foundation

// Loads the Advanced Rating plugin's config from Stash and parses
// it into typed groups + criteria for one domain (scene or
// performer). Direct port of src/rating/config.ts — same key
// layout, same parse logic, same defaults.
//
// The merged plugin stores both domains' config under a single
// plugin ID ("advancedRating") and namespaces keys by domain
// prefix:
//   scene_group_ids        = "<id1>,<id2>,..."
//   scene_group_name_<id>  = "Overall"
//   scene_group_weight_<id> = "1"
//   scene_criteria_ids     = "<id1>,<id2>,..."
//   scene_name_<id>        = "Production Quality"
//   scene_group_<id>       = "<group_id>"
//   scene_weight_<id>      = "1"
//   scene_enabled_<id>     = true / false
//   scene_desc_<id>        = "tooltip text"
//   performer_*            = same shape, performer domain
//
// We strip the domain prefix from each key on read and then
// parse the un-prefixed shape — per-criterion / per-group reads
// are identical regardless of domain.

private let PLUGIN_ID = "advancedRating"

@MainActor
final class RatingConfigLoader {
    static let shared = RatingConfigLoader()
    private init() {}

    /// Per-domain cache of the parsed config. Both domains read
    /// from the same plugin record so the raw fetch (below) is
    /// shared too.
    private var parsedCache: [RatingDomain: RatingConfig] = [:]
    private var rawCache: [String: Any]?
    private var rawFetchTask: Task<[String: Any]?, Never>?

    /// Load the config for a given domain. Idempotent — the raw
    /// fetch is shared across both domains and re-used across
    /// calls; the parsed result is also cached.
    func load(
        domain: RatingDomain,
        baseURL: String,
        apiKey: String
    ) async -> RatingConfig {
        if let cached = parsedCache[domain] { return cached }
        let raw = await rawConfig(baseURL: baseURL, apiKey: apiKey)
        let view = viewForDomain(raw: raw, domain: domain)
        let (groups, criteria) = parseConfig(domain: domain, view: view)
        let cfg = RatingConfig(
            domain: domain,
            groups: groups,
            criteria: criteria.filter(\.enabled)
        )
        parsedCache[domain] = cfg
        return cfg
    }

    func invalidate(domain: RatingDomain? = nil) {
        if let domain {
            parsedCache.removeValue(forKey: domain)
        } else {
            parsedCache.removeAll()
        }
        rawCache = nil
        rawFetchTask = nil
    }

    /// Single in-flight task for the raw fetch — concurrent
    /// callers from different domains dedupe.
    private func rawConfig(
        baseURL: String, apiKey: String
    ) async -> [String: Any]? {
        if let rawCache { return rawCache }
        if let existing = rawFetchTask {
            return await existing.value
        }
        let task = Task<[String: Any]?, Never> { [weak self] in
            let result = await Self.fetchPluginConfig(
                baseURL: baseURL, apiKey: apiKey
            )
            await self?.cacheRaw(result)
            return result
        }
        rawFetchTask = task
        return await task.value
    }

    private func cacheRaw(_ raw: [String: Any]?) {
        rawCache = raw
    }

    /// Raw HTTP query. Returns the plugin's config dictionary as
    /// `[String: Any]` (Stash's plugin config is an open
    /// JSON object — no fixed schema until we strip the prefix +
    /// coerce types ourselves).
    private static func fetchPluginConfig(
        baseURL: String, apiKey: String
    ) async -> [String: Any]? {
        let trimmed = baseURL.trimmingCharacters(
            in: .init(charactersIn: "/ \n\r\t")
        )
        guard let url = URL(string: "\(trimmed)/graphql") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.addValue(apiKey, forHTTPHeaderField: "ApiKey")
        }
        let body: [String: Any] = [
            "query": "query { configuration { plugins } }",
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return nil
            }
            guard
                let json =
                    try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let dataObj = json["data"] as? [String: Any],
                let config = dataObj["configuration"] as? [String: Any],
                let plugins = config["plugins"] as? [String: Any],
                let advanced = plugins[PLUGIN_ID] as? [String: Any]
            else {
                return nil
            }
            return advanced
        } catch {
            return nil
        }
    }

    /// Strip the domain prefix from every key — the parse logic
    /// below sees identical key names for either domain.
    private func viewForDomain(
        raw: [String: Any]?, domain: RatingDomain
    ) -> [String: Any] {
        guard let raw else { return [:] }
        let prefix = domain.rawValue + "_"
        var out: [String: Any] = [:]
        for (k, v) in raw where k.hasPrefix(prefix) {
            out[String(k.dropFirst(prefix.count))] = v
        }
        return out
    }
}

// MARK: - Parsing helpers (free functions, exposed for tests)

private func coerceBool(_ v: Any?, fallback: Bool) -> Bool {
    if let b = v as? Bool { return b }
    if let s = v as? String {
        let l = s.lowercased()
        if l == "true" || l == "1" { return true }
        if l == "false" || l == "0" { return false }
    }
    if let n = v as? NSNumber {
        return n.boolValue
    }
    return fallback
}

private func coerceFloat(_ v: Any?, fallback: Double) -> Double {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String, let d = Double(s) { return d }
    return fallback
}

private func coerceCsvIds(_ v: Any?) -> [String] {
    guard let s = v as? String else { return [] }
    return s.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// MARK: - Defaults — mirror plugin's empty-config behavior

private let SCENE_DEFAULT_GROUPS: [RatingGroup] = [
    .init(id: "overall", name: "Overall", weight: 1)
]
private let SCENE_DEFAULT_CRITERIA: [RatingCriterion] = [
    .init(id: "production_quality", name: "Production Quality", groupId: "overall", weight: 1, enabled: true, description: ""),
    .init(id: "chemistry", name: "Chemistry", groupId: "overall", weight: 1, enabled: true, description: ""),
    .init(id: "performance", name: "Performance", groupId: "overall", weight: 1, enabled: true, description: ""),
    .init(id: "aesthetics", name: "Aesthetics", groupId: "overall", weight: 1, enabled: true, description: ""),
    .init(id: "creativity", name: "Creativity", groupId: "overall", weight: 1, enabled: true, description: ""),
]

private let PERFORMER_DEFAULT_GROUPS: [RatingGroup] = [
    .init(id: "physical", name: "Physical", weight: 1),
    .init(id: "performance", name: "Performance", weight: 1),
]
private let PERFORMER_DEFAULT_CRITERIA: [RatingCriterion] = [
    .init(id: "face", name: "Face", groupId: "physical", weight: 1, enabled: true, description: ""),
    .init(id: "breasts", name: "Breasts", groupId: "physical", weight: 1, enabled: true, description: ""),
    .init(id: "ass", name: "Ass", groupId: "physical", weight: 1, enabled: true, description: ""),
    .init(id: "body", name: "Body", groupId: "physical", weight: 1, enabled: true, description: ""),
    .init(id: "genitals", name: "Genitals", groupId: "physical", weight: 1, enabled: true, description: ""),
    .init(id: "technique", name: "Technique", groupId: "performance", weight: 1, enabled: true, description: ""),
    .init(id: "energy", name: "Energy", groupId: "performance", weight: 1, enabled: true, description: ""),
    .init(id: "sluttiness", name: "Sluttiness", groupId: "performance", weight: 1, enabled: true, description: ""),
]

private func defaultsFor(_ domain: RatingDomain)
    -> (groups: [RatingGroup], criteria: [RatingCriterion])
{
    switch domain {
    case .performer:
        return (PERFORMER_DEFAULT_GROUPS, PERFORMER_DEFAULT_CRITERIA)
    case .scene:
        return (SCENE_DEFAULT_GROUPS, SCENE_DEFAULT_CRITERIA)
    }
}

/// Parse a domain-prefix-stripped config dict into typed
/// groups + criteria. Falls back to domain-appropriate defaults
/// when fields are missing — same behavior the plugin's own UI
/// uses when config is empty.
private func parseConfig(
    domain: RatingDomain, view: [String: Any]
) -> (groups: [RatingGroup], criteria: [RatingCriterion]) {
    let defaults = defaultsFor(domain)

    let groupIds = coerceCsvIds(view["group_ids"])
    let criteriaIds = coerceCsvIds(view["criteria_ids"])

    let groups: [RatingGroup]
    if groupIds.isEmpty {
        groups = defaults.groups
    } else {
        groups = groupIds.map { id in
            let fallback = defaults.groups.first(where: { $0.id == id })
                ?? RatingGroup(id: id, name: id, weight: 1)
            let name =
                (view["group_name_\(id)"] as? String) ?? fallback.name
            let weight = coerceFloat(
                view["group_weight_\(id)"], fallback: fallback.weight
            )
            return RatingGroup(id: id, name: name, weight: weight)
        }
    }

    let groupIdSet = Set(groups.map(\.id))

    let criteria: [RatingCriterion]
    if criteriaIds.isEmpty {
        criteria = defaults.criteria
    } else {
        criteria = criteriaIds.map { id in
            let fallback = defaults.criteria.first(where: { $0.id == id })
                ?? RatingCriterion(
                    id: id, name: id,
                    groupId: groups.first?.id ?? "",
                    weight: 1, enabled: true, description: ""
                )
            let groupId =
                (view["group_\(id)"] as? String) ?? fallback.groupId
            let legacyDisabled = coerceBool(
                view["disable_\(id)"], fallback: false
            )
            return RatingCriterion(
                id: id,
                name: (view["name_\(id)"] as? String) ?? fallback.name,
                groupId: groupIdSet.contains(groupId)
                    ? groupId : (groups.first?.id ?? ""),
                weight: coerceFloat(
                    view["weight_\(id)"], fallback: fallback.weight
                ),
                enabled: legacyDisabled
                    ? false
                    : coerceBool(
                        view["enabled_\(id)"],
                        fallback: fallback.enabled
                    ),
                description: (view["desc_\(id)"] as? String)
                    ?? fallback.description
            )
        }
    }

    return (groups, criteria)
}
