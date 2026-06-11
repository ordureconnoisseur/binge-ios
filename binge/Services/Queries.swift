import Foundation

// GraphQL query strings ported from the web plugin's src/api/queries.ts.
// One string per query, named identically so the cross-reference is
// obvious. Companion `Codable` response types live in Models/.
enum Mutations {
    /// Increment the scene's O-counter. Mirrors the web plugin's
    /// `sceneIncrementO` mutation — used by the double-tap-to-like
    /// gesture in the reel.
    static let sceneIncrementO = """
        mutation SceneIncrementO($id: ID!) {
            sceneIncrementO(id: $id)
        }
        """

    /// Decrement the O-counter. Paired with the reel heart's
    /// hold-to-unlike gesture (1.5s long-press).
    static let sceneDecrementO = """
        mutation SceneDecrementO($id: ID!) {
            sceneDecrementO(id: $id)
        }
        """

    /// Create a Stash tag. Used by CollectionsService to spawn
    /// the user's "Watch Later 📁" / "Favourite ★" tags on demand
    /// + any user-created " 📁" suffix collections. parent_ids
    /// optional — collection tags pass the "binge Collections"
    /// parent id so they nest under one hierarchy in Stash's tag
    /// tree.
    static let tagCreate = """
        mutation TagCreate(
          $name: String!,
          $ignoreAutoTag: Boolean!,
          $parentIds: [ID!]
        ) {
          tagCreate(input: {
            name: $name,
            ignore_auto_tag: $ignoreAutoTag,
            parent_ids: $parentIds
          }) {
            id
            name
          }
        }
        """

    /// Reparent an existing tag. Used by CollectionsService when
    /// migrating pre-hierarchy collection tags under the "binge
    /// Collections" parent.
    static let tagSetParents = """
        mutation TagSetParents($id: ID!, $parentIds: [ID!]!) {
          tagUpdate(input: { id: $id, parent_ids: $parentIds }) {
            id
          }
        }
        """

    /// Delete a Stash tag — drops its scene associations along
    /// with it. CollectionsService uses this when the user
    /// removes a non-default collection.
    static let tagDestroy = """
        mutation TagDestroy($id: ID!) {
          tagDestroy(input: { id: $id })
        }
        """

    /// Generic scene update — used by setSceneTags to swap the
    /// scene's tag list when toggling collection membership. Same
    /// mutation Stash uses everywhere; we only ever send tag_ids.
    static let sceneUpdateTags = """
        mutation SceneUpdateTags(
          $id: ID!,
          $tagIds: [ID!]!
        ) {
          sceneUpdate(input: { id: $id, tag_ids: $tagIds }) {
            id
            tags { id name }
          }
        }
        """

    /// Set the favourite flag on a performer. Stash's standard
    /// `performerUpdate` mutation, narrowed to just the favourite
    /// field so we don't accidentally clobber other attributes.
    /// Returns the updated favourite state for confirmation.
    static let performerFavorite = """
        mutation PerformerFavorite($id: ID!, $favorite: Boolean!) {
            performerUpdate(input: { id: $id, favorite: $favorite }) {
                id
                favorite
            }
        }
        """

    /// Wraps Stash's built-in stashbox scraper. Two layers of
    /// indirection (the scraper itself runs against StashDB, but
    /// Stash mediates so the returned shape lines up with
    /// PerformerCreateInput). v0.2: we hit StashDB directly for
    /// detail rendering and only use this for the
    /// followStashDBPerformer flow.
    static let scrapeStashBoxPerformer = """
        query ScrapeStashBoxPerformer(
            $stash_box_index: Int!, $stash_id: String!
        ) {
          scrapeSinglePerformer(
            source: { stash_box_index: $stash_box_index },
            input: { performer_id: $stash_id }
          ) {
            name disambiguation gender url twitter instagram
            birthdate ethnicity country eye_color hair_color
            height measurements fake_tits penis_length
            circumcised career_length tattoos piercings
            aliases images details death_date weight
            remote_site_id
          }
        }
        """

    /// Create a new local performer with the scraped fields +
    /// stash_ids backlink to StashDB. Carries enough to render
    /// the new performer in the user's library immediately;
    /// future "Refresh from StashDB" actions can fill any gaps.
    static let performerCreate = """
        mutation PerformerCreate($input: PerformerCreateInput!) {
          performerCreate(input: $input) { id name }
        }
        """

    /// Update a scene's tag_ids. Used by the rating modal —
    /// after a criterion score changes we build a new tag_ids
    /// list (existing tags minus the criterion's old score tag,
    /// plus the new score tag) and write it here. Stash's
    /// advancedRating Scene.Update.Post Python hook recomputes
    /// `rating100` server-side after this lands.
    static let sceneUpdateTagIds = """
        mutation SceneUpdateTagIds($input: SceneUpdateInput!) {
          sceneUpdate(input: $input) {
            id
            tags { id name }
          }
        }
        """

    /// Same pattern for performer ratings — performerUpdate with
    /// new tag_ids; the plugin's Performer.Update.Post hook
    /// recomputes rating100.
    static let performerUpdateTagIds = """
        mutation PerformerUpdateTagIds($input: PerformerUpdateInput!) {
          performerUpdate(input: $input) {
            id
            tags { id name }
          }
        }
        """

    /// Direct rating100 write — used by the BasicRatingModal
    /// fallback when the advancedRating plugin ISN'T installed.
    /// Stash's native field is 0–100; the modal converts from
    /// 1–5 stars at write time.
    static let sceneUpdateRating100 = """
        mutation SceneUpdateRating100($id: ID!, $rating: Int) {
          sceneUpdate(input: { id: $id, rating100: $rating }) {
            id
            rating100
          }
        }
        """
    static let performerUpdateRating100 = """
        mutation PerformerUpdateRating100($id: ID!, $rating: Int) {
          performerUpdate(input: { id: $id, rating100: $rating }) {
            id
            rating100
          }
        }
        """

    /// Create a new local scene with a stashbox backlink. Minimal
    /// fields — title, cover, urls, stash_ids — so future "scrape
    /// from StashDB" passes inside Stash can fill performers /
    /// studio / tags. Mirrors the web's submitSceneCreate but
    /// without the synchronous studio/performer lookup chain
    /// (that's the AddSceneModal's job; iOS keeps the flow tiny
    /// for v1).
    static let sceneCreate = """
        mutation SceneCreate($input: SceneCreateInput!) {
          sceneCreate(input: $input) { id title }
        }
        """

    /// LLM proxy through the stashScribe plugin. Stash's Python
    /// backend forwards the args to Ollama and returns the
    /// response atomically (no streaming). Same shape as
    /// src/scribe/api.ts RUN_PLUGIN_OP.
    static let runPluginOperation = """
        mutation RunScribeOp($plugin_id: ID!, $args: Map!) {
          runPluginOperation(plugin_id: $plugin_id, args: $args)
        }
        """

    /// sceneUpdate accepting the full Scribe save payload —
    /// `details` (stripped of any old review-marker block),
    /// `custom_fields.partial[stashScribe_review]`, and an
    /// optional new `tag_ids` list when the user opted to save
    /// scores. Wider than the rating module's
    /// `sceneUpdateTagIds` so we don't have to chain two
    /// mutations.
    static let sceneUpdateForScribe = """
        mutation SceneUpdateScribe($input: SceneUpdateInput!) {
          sceneUpdate(input: $input) { id }
        }
        """

    /// performerUpdate counterpart. Older Stash builds reject
    /// PerformerUpdateInput.custom_fields — the caller catches
    /// that and falls back to embedding the review in `details`
    /// via the same marker-block format the scene side strips on
    /// load.
    static let performerUpdateForScribe = """
        mutation PerformerUpdateScribe($input: PerformerUpdateInput!) {
          performerUpdate(input: $input) { id }
        }
        """

    /// Tag-by-exact-name lookup used by the Scribe save flow
    /// when resolving score-tag ids. Same shape as
    /// `Queries.findTagByExactName` but the Mutations side ships
    /// it too for callers that already use Mutations.
    static let scribeFindTagByName = """
        query FindTagForScribe($name: String!) {
          findTags(
            tag_filter: { name: { value: $name, modifier: EQUALS } },
            filter: { per_page: 1 }
          ) {
            tags { id name }
          }
        }
        """

    /// Create the missing score tag when autoCreate is on. The
    /// `ignore_auto_tag: true` flag mirrors the web's behavior so
    /// the rating plugin's auto-tagger doesn't fight the manual
    /// tag tree.
    static let scribeTagCreate = """
        mutation TagCreateScribe($input: TagCreateInput!) {
          tagCreate(input: $input) { id }
        }
        """
}

struct IncrementOResponse: Decodable {
    let sceneIncrementO: Int
}

struct DecrementOResponse: Decodable {
    let sceneDecrementO: Int
}

struct PerformerFavoriteResponse: Decodable {
    let performerUpdate: Payload
    struct Payload: Decodable {
        let id: String
        let favorite: Bool
    }
}

/// Wire response for scrapeSinglePerformer. Every field nullable —
/// scrapers regularly return partial data and we don't want a
/// single missing column to fail the whole decode.
struct ScrapeStashBoxPerformerResponse: Decodable {
    let scrapeSinglePerformer: [ScrapedPerformerPayload]?
}

struct ScrapedPerformerPayload: Decodable {
    let name: String?
    let disambiguation: String?
    let gender: String?
    let url: String?
    let twitter: String?
    let instagram: String?
    let birthdate: String?
    let ethnicity: String?
    let country: String?
    let eyeColor: String?
    let hairColor: String?
    let height: String?
    let measurements: String?
    let fakeTits: String?
    let penisLength: String?
    let circumcised: String?
    let careerLength: String?
    let tattoos: String?
    let piercings: String?
    let aliases: String?
    let images: [String]?
    let details: String?
    let deathDate: String?
    let weight: String?
    let remoteSiteId: String?

    enum CodingKeys: String, CodingKey {
        case name, disambiguation, gender, url, twitter, instagram
        case birthdate, ethnicity, country, height, measurements
        case tattoos, piercings, aliases, images, details
        case eyeColor = "eye_color"
        case hairColor = "hair_color"
        case fakeTits = "fake_tits"
        case penisLength = "penis_length"
        case circumcised
        case careerLength = "career_length"
        case deathDate = "death_date"
        case weight
        case remoteSiteId = "remote_site_id"
    }
}

struct PerformerCreateResponse: Decodable {
    let performerCreate: Payload
    struct Payload: Decodable {
        let id: String
        let name: String
    }
}

struct SceneCreateResponse: Decodable {
    let sceneCreate: Payload
    struct Payload: Decodable {
        let id: String
        let title: String?
    }
}

enum Queries {
    /// Connection check — used by SettingsView's "Connect" button.
    /// Returns Stash's running version; used only to confirm the
    /// URL + API key combination authenticates.
    static let version = """
        query Version { version { version } }
        """

    /// Random library scenes for the For-You reel. Mirrors
    /// findScenes() in src/api/queries.ts but only requests the
    /// fields v0.1 actually uses.
    ///
    /// `files.video_codec` is fetched so the reel can detect HEVC
    /// content and force a MP4 (H.264) transcode — AVPlayer's HEVC
    /// support is patchy across encoder profiles and a fallback is
    /// needed.
    ///
    /// `sceneStreams` mirrors what Stash's web UI uses to pick a
    /// transcode endpoint: list of `{url, label, mime_type}` where
    /// labels are like "Direct stream", "MP4", "WEBM", "HLS". We
    /// pick by label substring (matching the web app's pickStream).
    static let findScenesRandom = """
        query FindScenes($page: Int!, $perPage: Int!, $sort: String!) {
          findScenes(
            scene_filter: { \(HiddenContent.tagsExcludeClause) },
            filter: {
              page: $page,
              per_page: $perPage,
              sort: $sort,
              direction: DESC
            }
          ) {
            count
            scenes {
              id
              title
              details
              o_counter
              paths { stream screenshot preview }
              files {
                duration
                width
                height
                video_codec
                audio_codec
                frame_rate
                size
                bit_rate
                path
              }
              sceneStreams {
                url
                label
                mime_type
              }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Library scenes added recently — filter `created_at > $since`.
    /// Drives the Home tab's stories row + feed alongside
    /// `findScenesByDate`. Selection set is a superset of
    /// findScenesRandom (adds `created_at` + `date` for sort + the
    /// relative-time labels). BingeScene's optional fields cover
    /// the difference so one decoder handles every query.
    ///
    /// `since` is ISO 8601 ("yyyy-MM-ddTHH:mm:ssZ"). 30-day lookback
    /// is computed in HomeViewModel.
    static let findRecentScenes = """
        query RecentScenes($since: String!, $perPage: Int!) {
          findScenes(
            scene_filter: {
              created_at: { value: $since, modifier: GREATER_THAN },
              \(HiddenContent.tagsExcludeClause)
            },
            filter: {
              page: 1,
              per_page: $perPage,
              sort: "created_at",
              direction: DESC
            }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// findScenes with a free-form scene_filter + sort, used when
    /// a Stash saved filter is active in the reel. The
    /// `sceneFilter` GraphQL variable is `SceneFilterType` —
    /// we pass the deserialized object_filter JSON directly, which
    /// works because Stash treats the saved record's object_filter
    /// as exactly that input type.
    static let findScenesWithFilter = """
        query FilteredScenes(
          $page: Int!,
          $perPage: Int!,
          $sort: String!,
          $direction: SortDirectionEnum!,
          $sceneFilter: SceneFilterType
        ) {
          findScenes(
            scene_filter: $sceneFilter,
            filter: {
              page: $page,
              per_page: $perPage,
              sort: $sort,
              direction: $direction
            }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Exact-match tag lookup by name. Used by the collections
    /// service to find existing default tags (Favourite ★, Watch
    /// Later 📁) before lazy-creating them.
    static let findTagByName = """
        query FindTagByName($name: String!) {
          findTags(
            filter: { per_page: 1, sort: "name" },
            tag_filter: {
              name: { value: $name, modifier: EQUALS }
            }
          ) {
            tags { id name parents { id } }
          }
        }
        """

    /// Substring search across all tags. Drives the bulk-load of
    /// user-created collections (every tag whose name contains
    /// " 📁").
    static let findTagsContaining = """
        query FindTagsContaining($q: String!) {
          findTags(
            filter: { per_page: 500, sort: "name", q: $q }
          ) {
            tags { id name }
          }
        }
        """

    /// Scene grid for a single collection (tag). Sorted by
    /// updated_at DESC so the most-recently-saved scenes surface
    /// at the top.
    static let findScenesByTag = """
        query ScenesByTag(
          $tagId: ID!,
          $page: Int!,
          $perPage: Int!
        ) {
          findScenes(
            scene_filter: {
              tags: { value: [$tagId], modifier: INCLUDES }
            },
            filter: {
              page: $page,
              per_page: $perPage,
              sort: "updated_at",
              direction: DESC
            }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Up to 4 newest scenes per tag — drives the SavedPage
    /// tile's 2×2 cover grid (matches web's CollectionTile
    /// layout). Slim selection keeps the per-tile cost low.
    static let coverForTag = """
        query CoverForTag($tagId: ID!) {
          findScenes(
            scene_filter: {
              tags: { value: [$tagId], modifier: INCLUDES }
            },
            filter: {
              page: 1,
              per_page: 4,
              sort: "updated_at",
              direction: DESC
            }
          ) {
            count
            scenes {
              id
              paths { screenshot }
            }
          }
        }
        """

    /// Stash's local stashbox config — used to find the
    /// stashdb.org entry's API key for the discovery feed. Stash
    /// stores it under configuration.general.stashBoxes.
    static let findStashBoxConfig = """
        query Configuration {
          configuration {
            general {
              stashBoxes {
                endpoint
                api_key
                name
              }
            }
          }
        }
        """

    /// Local performers that have a stash_id link. Drives the
    /// discovery co-star seed — we hand StashDB this list of
    /// stash_ids and ask for their recent scenes.
    static let findLinkedPerformers = """
        query LinkedPerformers {
          findPerformers(filter: { per_page: -1 }) {
            performers {
              id
              name
              favorite
              image_path
              stash_ids { endpoint stash_id }
            }
          }
        }
        """

    /// Scene stash_ids the user already has imported locally —
    /// used to filter discovered StashDB scenes so we don't
    /// surface ones the user already owns.
    static let findOwnedStashIds = """
        query OwnedStashIds {
          findScenes(filter: { per_page: -1 }) {
            scenes {
              stash_ids { endpoint stash_id }
            }
          }
        }
        """

    /// Look up a single tag by exact name match. The rating
    /// modal uses this to resolve a score tag name ("Production
    /// Quality ★: 4") → tag id before writing. binge does NOT
    /// auto-create score tags — they belong under the plugin's
    /// own parent-tag tree, and creating from outside that tree
    /// would orphan them.
    static let findTagByExactName = """
        query FindTagByExactName($name: String!) {
          findTags(
            tag_filter: { name: { value: $name, modifier: EQUALS } },
            filter: { per_page: 1 }
          ) {
            tags { id name }
          }
        }
        """

    /// Re-read a scene's tags + rating100 after a write so the
    /// rating modal can pick up the plugin hook's recomputed value.
    static let findSceneTagsAndRating = """
        query FindSceneTagsAndRating($id: ID!) {
          findScene(id: $id) {
            id
            rating100
            tags { id name }
          }
        }
        """

    /// Performer counterpart of findSceneTagsAndRating.
    static let findPerformerTagsAndRating = """
        query FindPerformerTagsAndRating($id: ID!) {
          findPerformer(id: $id) {
            id
            rating100
            tags { id name }
          }
        }
        """

    /// Scribe scene fetch — every field the system prompt needs.
    /// custom_fields is a JSON scalar (Stash returns it as Map);
    /// decoded as [String: JSONValue] on the iOS side.
    static let sceneForScribe = """
        query SceneForScribe($id: ID!) {
          findScene(id: $id) {
            id title date details rating100 custom_fields
            o_counter play_count
            studio { name }
            performers {
              name gender birthdate ethnicity hair_color eye_color
              height_cm measurements fake_tits tattoos piercings
            }
            tags { id name }
          }
        }
        """

    /// Scribe performer profile fetch — separate from the
    /// existing findPerformer because Scribe needs more bio
    /// fields (custom_fields, career_length, death_date, etc.).
    static let performerForScribe = """
        query PerformerForScribe($id: ID!) {
          findPerformer(id: $id) {
            id name details rating100 custom_fields
            birthdate death_date country ethnicity
            hair_color eye_color height_cm weight measurements
            fake_tits gender favorite career_length
            tattoos piercings alias_list
            tags { id name }
          }
        }
        """

    /// Every scene a performer appears in — drives the Scribe
    /// performer aggregate (scene count, total o-counter, top
    /// tags/studios, notable scenes). Heavy fetch (per_page:
    /// -1) but only fires when Scribe opens on a performer.
    static let performerScenesForScribe = """
        query ScenesForPerformerAgg($id: ID!) {
          findScenes(
            scene_filter: { performers: { value: [$id], modifier: INCLUDES } },
            filter: { per_page: -1 }
          ) {
            count
            scenes {
              id title rating100 o_counter play_count date
              details custom_fields
              studio { name }
              tags { name }
            }
          }
        }
        """

    /// Installed Stash plugins + their enabled flag. Powers the
    /// PluginContext singleton — binge gates plugin-coupled UI
    /// (advanced rating modal, etc.) on a matching id appearing
    /// here with `enabled: true`.
    static let installedPlugins = """
        query InstalledPlugins {
          plugins { id enabled }
        }
        """

    /// All local studios + their stash_ids. Used by the Add-Scene
    /// flow to resolve a StashDB studio stash_id → local studio
    /// id so the new scene gets attached to the right studio.
    static let findStudiosWithStashIds = """
        query StudiosWithStashIds {
          findStudios(filter: { per_page: -1 }) {
            studios {
              id
              stash_ids { endpoint stash_id }
            }
          }
        }
        """

    /// Stash's native saved scene filters. `object_filter` is a
    /// JSON scalar — its shape depends on the saved filter's
    /// criteria; we decode it via JSONValue and pass it straight
    /// back into findScenes when applying.
    static let findSavedFilters = """
        query SavedFiltersForScenes {
          findSavedFilters(mode: SCENES) {
            id
            name
            find_filter {
              q
              sort
              direction
            }
            object_filter
          }
        }
        """

    /// Random pool of scenes filtered by an INCLUDES list of
    /// performer IDs — used by ChainAlgo to pull candidates that
    /// share performers with what the user's been watching.
    static let findScenesByPerformersRandom = """
        query ScenesByPerformersRandom(
          $performerIds: [ID!]!,
          $perPage: Int!
        ) {
          findScenes(
            scene_filter: {
              performers: { value: $performerIds, modifier: INCLUDES }
            },
            filter: { page: 1, per_page: $perPage, sort: "random" }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Same idea but for tags — pulls candidates that share tag
    /// IDs with the user's recent plays.
    static let findScenesByTagsRandom = """
        query ScenesByTagsRandom($tagIds: [ID!]!, $perPage: Int!) {
          findScenes(
            scene_filter: {
              tags: { value: $tagIds, modifier: INCLUDES }
            },
            filter: { page: 1, per_page: $perPage, sort: "random" }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Random-sorted scene grid for the Explore tab. `sort` accepts
    /// Stash's `random_<int>` form so pagination across pages stays
    /// stable (without a fixed seed, page 2 would be a fresh
    /// shuffle and produce duplicates). `q` is a text search across
    /// scene title / details / performer names — empty string
    /// matches all.
    static let findScenesExplore = """
        query ExploreScenes(
          $page: Int!,
          $perPage: Int!,
          $sort: String!,
          $q: String!,
          $sceneFilter: SceneFilterType
        ) {
          findScenes(
            scene_filter: $sceneFilter,
            filter: {
              page: $page,
              per_page: $perPage,
              sort: $sort,
              direction: DESC,
              q: $q
            }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Pulls tags from the user's most-recently-liked scenes — used
    /// as the server-side fallback for Explore's chip strip when
    /// the local InteractedTagsStore hasn't accumulated enough
    /// signal yet. Mirrors web's `FIND_RECENTLY_LIKED_SCENES`.
    static let findRecentlyLikedScenes = """
        query FindRecentlyLikedScenes($perPage: Int!) {
          findScenes(
            scene_filter: {
              o_counter: { value: 0, modifier: GREATER_THAN }
            }
            filter: {
              page: 1,
              per_page: $perPage,
              sort: "last_o_at",
              direction: DESC
            }
          ) {
            scenes {
              id
              tags { id name }
            }
          }
        }
        """

    /// One page of all performers sorted by name ASC. Used by the
    /// Following tab via PerformerSweep — sweeps pages until the
    /// server's `count` is reached.
    static let findPerformersPage = """
        query AllPerformers($page: Int!, $perPage: Int!) {
          findPerformers(
            filter: {
              page: $page,
              per_page: $perPage,
              sort: "name",
              direction: ASC
            }
          ) {
            count
            performers {
              id
              name
              image_path
              scene_count
              favorite
            }
          }
        }
        """

    /// Full performer detail by id — drives PerformerProfileSheet.
    /// Mirrors the web's FIND_PERFORMER query. Tags and stash_ids
    /// are omitted from this selection for v0.2 — they're not
    /// rendered in the first-cut profile UI.
    static let findPerformer = """
        query Performer($id: ID!) {
          findPerformer(id: $id) {
            id
            name
            alias_list
            favorite
            image_path
            details
            country
            birthdate
            hair_color
            eye_color
            scene_count
            gallery_count
            o_counter
            rating100
            twitter
            instagram
            url
            urls
            stash_ids { endpoint stash_id }
          }
        }
        """

    /// Library scenes for a given performer, newest-first. Reuses
    /// BingeScene's selection set so the same decoder + screenshot
    /// helpers work for the grid thumbnails.
    static let findScenesForPerformer = """
        query ScenesForPerformer(
          $performerId: ID!,
          $page: Int!,
          $perPage: Int!,
          $sort: String!
        ) {
          findScenes(
            scene_filter: {
              performers: { value: [$performerId], modifier: INCLUDES_ALL }
            },
            filter: {
              page: $page,
              per_page: $perPage,
              sort: $sort,
              direction: DESC
            }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              play_count
              rating100
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """

    /// Library scenes RELEASED recently — filter `date > $since`.
    /// Catches the case where a freshly-released scene was imported
    /// long ago, so a `created_at`-only query would miss it. Run in
    /// parallel with findRecentScenes; merge by scene id.
    ///
    /// `since` is bare "YYYY-MM-DD" (Stash's date-field precision).
    static let findScenesByDate = """
        query ScenesByDate($since: String!, $perPage: Int!) {
          findScenes(
            scene_filter: {
              date: { value: $since, modifier: GREATER_THAN },
              \(HiddenContent.tagsExcludeClause)
            },
            filter: {
              page: 1,
              per_page: $perPage,
              sort: "date",
              direction: DESC
            }
          ) {
            count
            scenes {
              id
              title
              details
              created_at
              date
              o_counter
              paths { stream screenshot preview }
              files { duration width height video_codec audio_codec frame_rate size bit_rate path }
              sceneStreams { url label mime_type }
              performers { id name image_path favorite gender }
              studio { name }
              tags { id name }
            }
          }
        }
        """
}

// MARK: – Response types

struct VersionResponse: Decodable {
    let version: VersionPayload
    struct VersionPayload: Decodable { let version: String }
}

struct FindStashBoxConfigResponse: Decodable {
    let configuration: Configuration
    struct Configuration: Decodable {
        let general: General
    }
    struct General: Decodable {
        let stashBoxes: [Box]
    }
    struct Box: Decodable {
        let endpoint: String
        let apiKey: String
        let name: String?
        enum CodingKeys: String, CodingKey {
            case endpoint
            case apiKey = "api_key"
            case name
        }
    }
}

struct FindLinkedPerformersResponse: Decodable {
    let findPerformers: Payload
    struct Payload: Decodable {
        let performers: [Performer]
    }
    struct Performer: Decodable {
        let id: String
        let name: String
        let favorite: Bool
        let imagePath: String?
        let stashIds: [StashIdLink]
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case favorite
            case imagePath = "image_path"
            case stashIds = "stash_ids"
        }
    }
    struct StashIdLink: Decodable {
        let endpoint: String
        let stashId: String
        enum CodingKeys: String, CodingKey {
            case endpoint
            case stashId = "stash_id"
        }
    }
}

struct FindOwnedStashIdsResponse: Decodable {
    let findScenes: Payload
    struct Payload: Decodable {
        let scenes: [Scene]
    }
    struct Scene: Decodable {
        let stashIds: [StashIdLink]
        enum CodingKeys: String, CodingKey {
            case stashIds = "stash_ids"
        }
    }
    struct StashIdLink: Decodable {
        let endpoint: String
        let stashId: String
        enum CodingKeys: String, CodingKey {
            case endpoint
            case stashId = "stash_id"
        }
    }
}

/// Performer counterpart to the existing `SceneUpdateTagsResponse`
/// (defined further down for the collections feature) — used by
/// the rating modal's performerUpdate call.
struct PerformerUpdateTagsResponse: Decodable {
    let performerUpdate: Payload
    struct Payload: Decodable {
        let id: String
        let tags: [StashTag]
    }
}

/// Shared response shape for the rating100 writes — both scene
/// and performer return id + rating100 from the mutation.
struct SceneUpdateRating100Response: Decodable {
    let sceneUpdate: Payload
    struct Payload: Decodable {
        let id: String
        let rating100: Int?
    }
}

struct PerformerUpdateRating100Response: Decodable {
    let performerUpdate: Payload
    struct Payload: Decodable {
        let id: String
        let rating100: Int?
    }
}

struct FindTagByExactNameResponse: Decodable {
    let findTags: Payload
    struct Payload: Decodable {
        let tags: [Tag]
    }
    struct Tag: Decodable {
        let id: String
        let name: String
    }
}

struct FindSceneTagsAndRatingResponse: Decodable {
    let findScene: Payload?
    struct Payload: Decodable {
        let id: String
        let rating100: Int?
        let tags: [TagMin]
    }
    struct TagMin: Decodable {
        let id: String
        let name: String
    }
}

struct FindPerformerTagsAndRatingResponse: Decodable {
    let findPerformer: Payload?
    struct Payload: Decodable {
        let id: String
        let rating100: Int?
        let tags: [TagMin]
    }
    struct TagMin: Decodable {
        let id: String
        let name: String
    }
}

// MARK: - Scribe response shapes

/// Wire shape of `sceneForScribe` — all optional except id.
/// `customFields` is a JSON scalar (Stash returns Map). The
/// review text lives under custom_fields[stashScribe_review].
struct SceneForScribeResponse: Decodable {
    let findScene: Scene?
    struct Scene: Decodable {
        let id: String
        let title: String?
        let date: String?
        let details: String?
        let rating100: Int?
        let oCounter: Int?
        let playCount: Int?
        let customFields: [String: JSONValue]?
        let studio: Studio?
        let performers: [Performer]
        let tags: [Tag]

        enum CodingKeys: String, CodingKey {
            case id, title, date, details, rating100
            case oCounter = "o_counter"
            case playCount = "play_count"
            case customFields = "custom_fields"
            case studio, performers, tags
        }

        struct Studio: Decodable { let name: String? }
        struct Tag: Decodable {
            let id: String
            let name: String
        }
        struct Performer: Decodable {
            let name: String?
            let gender: String?
            let birthdate: String?
            let ethnicity: String?
            let hairColor: String?
            let eyeColor: String?
            let heightCm: Int?
            let measurements: String?
            let fakeTits: String?
            let tattoos: String?
            let piercings: String?

            enum CodingKeys: String, CodingKey {
                case name, gender, birthdate, ethnicity, measurements
                case hairColor = "hair_color"
                case eyeColor = "eye_color"
                case heightCm = "height_cm"
                case fakeTits = "fake_tits"
                case tattoos, piercings
            }
        }
    }
}

struct PerformerForScribeResponse: Decodable {
    let findPerformer: Performer?
    struct Performer: Decodable {
        let id: String
        let name: String
        let details: String?
        let rating100: Int?
        let customFields: [String: JSONValue]?
        let birthdate: String?
        let deathDate: String?
        let country: String?
        let ethnicity: String?
        let hairColor: String?
        let eyeColor: String?
        let heightCm: Int?
        let weight: Int?
        let measurements: String?
        let fakeTits: String?
        let gender: String?
        let favorite: Bool?
        let careerLength: String?
        let tattoos: String?
        let piercings: String?
        let aliasList: [String]?
        let tags: [Tag]

        enum CodingKeys: String, CodingKey {
            case id, name, details, rating100, birthdate, country
            case ethnicity, weight, measurements, gender, favorite
            case tattoos, piercings, tags
            case customFields = "custom_fields"
            case deathDate = "death_date"
            case hairColor = "hair_color"
            case eyeColor = "eye_color"
            case heightCm = "height_cm"
            case fakeTits = "fake_tits"
            case careerLength = "career_length"
            case aliasList = "alias_list"
        }
        struct Tag: Decodable {
            let id: String
            let name: String
        }
    }
}

struct PerformerScenesForScribeResponse: Decodable {
    let findScenes: Payload
    struct Payload: Decodable {
        let count: Int
        let scenes: [Scene]
    }
    struct Scene: Decodable {
        let id: String
        let title: String?
        let rating100: Int?
        let oCounter: Int?
        let playCount: Int?
        let date: String?
        let details: String?
        let customFields: [String: JSONValue]?
        let studio: Studio?
        let tags: [Tag]

        enum CodingKeys: String, CodingKey {
            case id, title, rating100, date, details, studio, tags
            case oCounter = "o_counter"
            case playCount = "play_count"
            case customFields = "custom_fields"
        }
        struct Studio: Decodable { let name: String? }
        struct Tag: Decodable { let name: String }
    }
}

/// runPluginOperation returns an open Map scalar. The Scribe
/// plugin packs `content` (chat reply) or `models` (model list)
/// or `error` into it.
struct RunPluginOperationResponse: Decodable {
    let runPluginOperation: Payload?
    struct Payload: Decodable {
        let content: String?
        let models: [String]?
        let error: String?
    }
}

struct ScribeFindTagResponse: Decodable {
    let findTags: Payload
    struct Payload: Decodable {
        let tags: [Tag]
    }
    struct Tag: Decodable {
        let id: String
        let name: String
    }
}

struct ScribeTagCreateResponse: Decodable {
    let tagCreate: Payload
    struct Payload: Decodable {
        let id: String
    }
}

/// Plugin configuration fetch — same wire shape the rating
/// module uses but exposed here for Scribe's getScribeConfig.
/// `plugins` is a JSON Map keyed by plugin id; each value is an
/// open dictionary of plugin-specific config keys.
struct PluginsConfigurationResponse: Decodable {
    let configuration: Configuration
    struct Configuration: Decodable {
        let plugins: [String: JSONValue]
    }
}

struct InstalledPluginsResponse: Decodable {
    let plugins: [Plugin]
    struct Plugin: Decodable {
        let id: String
        let enabled: Bool
    }
}

struct FindStudiosWithStashIdsResponse: Decodable {
    let findStudios: Payload
    struct Payload: Decodable {
        let studios: [Studio]
    }
    struct Studio: Decodable {
        let id: String
        let stashIds: [StashIdLink]
        enum CodingKeys: String, CodingKey {
            case id
            case stashIds = "stash_ids"
        }
    }
    struct StashIdLink: Decodable {
        let endpoint: String
        let stashId: String
        enum CodingKeys: String, CodingKey {
            case endpoint
            case stashId = "stash_id"
        }
    }
}

struct TagCreateResponse: Decodable {
    let tagCreate: StashTag
}

struct TagDestroyResponse: Decodable {
    let tagDestroy: Bool
}

struct SceneUpdateTagsResponse: Decodable {
    let sceneUpdate: Payload
    struct Payload: Decodable {
        let id: String
        let tags: [StashTag]
    }
}

/// Slim cover-image response — just enough to render the SavedPage
/// tile's thumbnail.
struct CoverForTagResponse: Decodable {
    let findScenes: Payload
    struct Payload: Decodable {
        let count: Int
        let scenes: [CoverScene]
    }
    struct CoverScene: Decodable {
        let id: String
        let paths: Paths
        struct Paths: Decodable {
            let screenshot: String?
        }
    }
}
