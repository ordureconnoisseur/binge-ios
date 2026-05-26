import Foundation

// StashDB integration types. Mirrors src/api/stashdb.ts shapes —
// renamed to camelCase via CodingKeys since StashDB returns
// snake_case.

/// Stash's stored stashbox endpoint + auth, sourced via the local
/// Stash's `configuration.general.stashBoxes`. We only care about
/// the entry pointing at https://stashdb.org/graphql.
struct StashBoxConfig: Codable, Hashable {
    let endpoint: String
    let apiKey: String
    /// Position in Stash's stashBoxes list — needed by the
    /// follow-from-StashDB scraper later (not used in v0.2).
    let index: Int
}

/// Local Stash performer that has a stash_id link pointing to
/// stashdb.org. Drives the discovery co-star seed: we ask StashDB
/// for new scenes featuring any of these stash_ids.
struct LinkedPerformer: Codable, Hashable, Identifiable {
    var id: String { localId }
    let localId: String
    let stashId: String
    let name: String
    let favorite: Bool
    let imagePath: String?
}

/// One StashDB scene as returned by queryScenes. `performers`
/// is flattened — the raw API returns
/// `performers: [{ performer: {...} }]` and we strip the wrapper
/// during decode so consumers don't have to.
struct StashDBScene: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let releaseDate: String?
    let coverUrl: String?
    let performers: [StashDBPerformer]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case releaseDate = "release_date"
        case images
        case performers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try? c.decode(String.self, forKey: .title)
        releaseDate = try? c.decode(String.self, forKey: .releaseDate)
        let images = (try? c.decode([ImageURL].self, forKey: .images)) ?? []
        coverUrl = images.first?.url
        let wrappedPerformers =
            (try? c.decode([PerformerWrap].self, forKey: .performers)) ?? []
        performers = wrappedPerformers.compactMap { $0.performer }
    }

    private struct ImageURL: Decodable {
        let url: String
    }

    private struct PerformerWrap: Decodable {
        let performer: StashDBPerformer?
    }
}

/// StashDB performer record. `image` is the first image URL
/// flattened from `images: [{url}]`.
struct StashDBPerformer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// StashDB gender enum: FEMALE / MALE / TRANSGENDER_FEMALE /
    /// TRANSGENDER_MALE / INTERSEX / NON_BINARY / null.
    let gender: String?
    let birthDate: String?
    let sceneCount: Int
    let image: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gender
        case birthDate = "birth_date"
        case sceneCount = "scene_count"
        case images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        gender = try? c.decode(String.self, forKey: .gender)
        birthDate = try? c.decode(String.self, forKey: .birthDate)
        sceneCount = (try? c.decode(Int.self, forKey: .sceneCount)) ?? 0
        let images = (try? c.decode([ImageURL].self, forKey: .images)) ?? []
        image = images.first?.url
    }

    private struct ImageURL: Decodable { let url: String }
}

/// Wire-level GraphQL response wrapping the QueryScenes shape.
struct QueryScenesResponse: Decodable {
    let queryScenes: Payload
    struct Payload: Decodable {
        let scenes: [StashDBScene]
    }
}

/// Full StashDB performer detail — populates the read-only profile
/// view for performers the user hasn't added to their library yet.
/// Maps the same field set as web's `StashDBPerformerDetail`,
/// pre-formatting `measurements` to the conventional "32B-24-34"
/// string Stash uses.
struct StashDBPerformerDetail: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let disambiguation: String?
    let gender: String?
    let birthDate: String?
    let careerStartYear: Int?
    let careerEndYear: Int?
    /// Height in cm.
    let height: Int?
    let hairColor: String?
    let eyeColor: String?
    let ethnicity: String?
    let country: String?
    /// "FAKE" / "NATURAL" / nil.
    let breastType: String?
    let aliases: [String]
    let sceneCount: Int
    /// Pre-formatted "<band><cup>-<waist>-<hip>" string when all
    /// pieces are present; partial subsets render the available
    /// pieces joined by "-".
    let measurements: String?
    let images: [String]
    let urls: [URLEntry]
    let tattoos: [BodyMark]
    let piercings: [BodyMark]

    struct URLEntry: Hashable {
        let url: String
        let site: String
    }
    struct BodyMark: Hashable {
        let location: String
        let description: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, disambiguation, gender, ethnicity, country
        case aliases, images, urls, tattoos, piercings
        case birthDate = "birth_date"
        case careerStartYear = "career_start_year"
        case careerEndYear = "career_end_year"
        case height
        case hairColor = "hair_color"
        case eyeColor = "eye_color"
        case breastType = "breast_type"
        case cupSize = "cup_size"
        case bandSize = "band_size"
        case waistSize = "waist_size"
        case hipSize = "hip_size"
        case sceneCount = "scene_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        disambiguation = try? c.decode(String.self, forKey: .disambiguation)
        gender = try? c.decode(String.self, forKey: .gender)
        birthDate = try? c.decode(String.self, forKey: .birthDate)
        careerStartYear = try? c.decode(Int.self, forKey: .careerStartYear)
        careerEndYear = try? c.decode(Int.self, forKey: .careerEndYear)
        height = try? c.decode(Int.self, forKey: .height)
        hairColor = try? c.decode(String.self, forKey: .hairColor)
        eyeColor = try? c.decode(String.self, forKey: .eyeColor)
        ethnicity = try? c.decode(String.self, forKey: .ethnicity)
        country = try? c.decode(String.self, forKey: .country)
        breastType = try? c.decode(String.self, forKey: .breastType)
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        sceneCount = (try? c.decode(Int.self, forKey: .sceneCount)) ?? 0
        let imgs = (try? c.decode([ImageURL].self, forKey: .images)) ?? []
        images = imgs.map(\.url)
        let urlPayloads =
            (try? c.decode([URLPayload].self, forKey: .urls)) ?? []
        urls = urlPayloads.map { URLEntry(url: $0.url, site: $0.site.name) }
        let tats =
            (try? c.decode([BodyMarkPayload].self, forKey: .tattoos)) ?? []
        tattoos = tats.map {
            BodyMark(location: $0.location, description: $0.description)
        }
        let pcs =
            (try? c.decode([BodyMarkPayload].self, forKey: .piercings)) ?? []
        piercings = pcs.map {
            BodyMark(location: $0.location, description: $0.description)
        }
        // Compose the measurements string from the four separate
        // numeric/string columns StashDB exposes. Matches web's
        // formatMeasurements helper.
        let band = try? c.decode(Int.self, forKey: .bandSize)
        let cup = try? c.decode(String.self, forKey: .cupSize)
        let waist = try? c.decode(Int.self, forKey: .waistSize)
        let hip = try? c.decode(Int.self, forKey: .hipSize)
        let top: String? = {
            if let band, let cup { return "\(band)\(cup)" }
            return nil
        }()
        let parts: [String] = [
            top, waist.map { "\($0)" }, hip.map { "\($0)" },
        ].compactMap { $0 }
        measurements = parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    private struct ImageURL: Decodable { let url: String }
    private struct URLPayload: Decodable {
        let url: String
        let site: Site
        struct Site: Decodable { let name: String }
    }
    private struct BodyMarkPayload: Decodable {
        let location: String
        let description: String?
    }
}

struct QueryPerformerResponse: Decodable {
    let findPerformer: StashDBPerformerDetail?
}

/// Full StashDB scene record — populates the Add-Scene flow so
/// sceneCreate can ship title/date/code/details/etc. instead of
/// just the four fields the discovery card carries. Mirrors web's
/// StashDBSceneDetail.
struct StashDBSceneDetail: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let details: String?
    let releaseDate: String?
    let code: String?
    let director: String?
    let urls: [URLEntry]
    let studioStashId: String?
    let performerStashIds: [String]
    let images: [String]

    struct URLEntry: Hashable {
        let url: String
        let site: String
    }

    enum CodingKeys: String, CodingKey {
        case id, title, details, code, director, urls
        case releaseDate = "release_date"
        case studio, performers, images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try? c.decode(String.self, forKey: .title)
        details = try? c.decode(String.self, forKey: .details)
        releaseDate = try? c.decode(String.self, forKey: .releaseDate)
        code = try? c.decode(String.self, forKey: .code)
        director = try? c.decode(String.self, forKey: .director)
        let urlPayloads =
            (try? c.decode([URLPayload].self, forKey: .urls)) ?? []
        urls = urlPayloads.map {
            URLEntry(url: $0.url, site: $0.site.name)
        }
        let studio = try? c.decode(Studio.self, forKey: .studio)
        studioStashId = studio?.id
        let perfWraps =
            (try? c.decode([PerformerWrap].self, forKey: .performers)) ?? []
        performerStashIds = perfWraps.map(\.performer.id)
        let imgs = (try? c.decode([ImageURL].self, forKey: .images)) ?? []
        images = imgs.map(\.url)
    }

    private struct URLPayload: Decodable {
        let url: String
        let site: Site
        struct Site: Decodable { let name: String }
    }
    private struct Studio: Decodable {
        let id: String
        let name: String?
    }
    private struct PerformerWrap: Decodable {
        let performer: P
        struct P: Decodable {
            let id: String
            let name: String?
        }
    }
    private struct ImageURL: Decodable { let url: String }
}

struct QuerySceneResponse: Decodable {
    let findScene: StashDBSceneDetail?
}

/// Trim StashDB performer for the Discover bar — only the
/// fields the bubble needs. Same shape as web's
/// StashDBTrendingPerformer.
struct StashDBTrendingPerformer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let gender: String?
    let birthDate: String?
    let image: String?
    let sceneCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, gender, images
        case birthDate = "birth_date"
        case sceneCount = "scene_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        gender = try? c.decode(String.self, forKey: .gender)
        birthDate = try? c.decode(String.self, forKey: .birthDate)
        sceneCount = (try? c.decode(Int.self, forKey: .sceneCount)) ?? 0
        let imgs = (try? c.decode([ImageURL].self, forKey: .images)) ?? []
        image = imgs.first?.url
    }

    private struct ImageURL: Decodable { let url: String }
}

struct QueryPerformersResponse: Decodable {
    let queryPerformers: Payload
    struct Payload: Decodable {
        let performers: [StashDBTrendingPerformer]
    }
}

// MARK: - Cache snapshots
//
// Pure-Codable mirrors of the in-memory shapes — round-tripped
// through StashDBCache. Conversion helpers (`snapshot` /
// `init(snapshot:)`) keep the wire decoders untouched so we
// don't have to teach `init(from decoder:)` to recognize two
// schemas.

extension StashDBPerformer {
    struct Snapshot: Codable {
        let id: String
        let name: String
        let gender: String?
        let birthDate: String?
        let sceneCount: Int
        let image: String?
    }
    var snapshot: Snapshot {
        Snapshot(
            id: id, name: name, gender: gender,
            birthDate: birthDate, sceneCount: sceneCount, image: image
        )
    }
    init(snapshot s: Snapshot) {
        self.id = s.id
        self.name = s.name
        self.gender = s.gender
        self.birthDate = s.birthDate
        self.sceneCount = s.sceneCount
        self.image = s.image
    }
}

extension StashDBScene {
    struct Snapshot: Codable {
        let id: String
        let title: String?
        let releaseDate: String?
        let coverUrl: String?
        let performers: [StashDBPerformer.Snapshot]
    }
    var snapshot: Snapshot {
        Snapshot(
            id: id, title: title, releaseDate: releaseDate,
            coverUrl: coverUrl,
            performers: performers.map(\.snapshot)
        )
    }
    init(snapshot s: Snapshot) {
        self.id = s.id
        self.title = s.title
        self.releaseDate = s.releaseDate
        self.coverUrl = s.coverUrl
        self.performers = s.performers.map(StashDBPerformer.init)
    }
}

extension StashDBTrendingPerformer {
    struct Snapshot: Codable {
        let id: String
        let name: String
        let gender: String?
        let birthDate: String?
        let image: String?
        let sceneCount: Int
    }
    var snapshot: Snapshot {
        Snapshot(
            id: id, name: name, gender: gender,
            birthDate: birthDate, image: image, sceneCount: sceneCount
        )
    }
    init(snapshot s: Snapshot) {
        self.id = s.id
        self.name = s.name
        self.gender = s.gender
        self.birthDate = s.birthDate
        self.image = s.image
        self.sceneCount = s.sceneCount
    }
}

extension StashDBPerformerDetail {
    struct Snapshot: Codable {
        let id: String
        let name: String
        let disambiguation: String?
        let gender: String?
        let birthDate: String?
        let careerStartYear: Int?
        let careerEndYear: Int?
        let height: Int?
        let hairColor: String?
        let eyeColor: String?
        let ethnicity: String?
        let country: String?
        let breastType: String?
        let aliases: [String]
        let sceneCount: Int
        let measurements: String?
        let images: [String]
        let urls: [URLEntrySnapshot]
        let tattoos: [BodyMarkSnapshot]
        let piercings: [BodyMarkSnapshot]
        struct URLEntrySnapshot: Codable {
            let url: String
            let site: String
        }
        struct BodyMarkSnapshot: Codable {
            let location: String
            let description: String?
        }
    }
    var snapshot: Snapshot {
        Snapshot(
            id: id, name: name, disambiguation: disambiguation,
            gender: gender, birthDate: birthDate,
            careerStartYear: careerStartYear,
            careerEndYear: careerEndYear,
            height: height, hairColor: hairColor, eyeColor: eyeColor,
            ethnicity: ethnicity, country: country,
            breastType: breastType, aliases: aliases,
            sceneCount: sceneCount, measurements: measurements,
            images: images,
            urls: urls.map {
                .init(url: $0.url, site: $0.site)
            },
            tattoos: tattoos.map {
                .init(location: $0.location, description: $0.description)
            },
            piercings: piercings.map {
                .init(location: $0.location, description: $0.description)
            }
        )
    }
    init(snapshot s: Snapshot) {
        self.id = s.id
        self.name = s.name
        self.disambiguation = s.disambiguation
        self.gender = s.gender
        self.birthDate = s.birthDate
        self.careerStartYear = s.careerStartYear
        self.careerEndYear = s.careerEndYear
        self.height = s.height
        self.hairColor = s.hairColor
        self.eyeColor = s.eyeColor
        self.ethnicity = s.ethnicity
        self.country = s.country
        self.breastType = s.breastType
        self.aliases = s.aliases
        self.sceneCount = s.sceneCount
        self.measurements = s.measurements
        self.images = s.images
        self.urls = s.urls.map {
            URLEntry(url: $0.url, site: $0.site)
        }
        self.tattoos = s.tattoos.map {
            BodyMark(location: $0.location, description: $0.description)
        }
        self.piercings = s.piercings.map {
            BodyMark(location: $0.location, description: $0.description)
        }
    }
}
