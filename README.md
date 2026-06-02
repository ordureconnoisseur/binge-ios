<p align="center"><img src="banner/banner-1280x400.png" alt="binge — Reels, stories, and discovery for your Stash library." width="1000" /></p>

Native iOS client for [Stash](https://github.com/stashapp/stash). Sister project of the [binge web plugin](https://github.com/ordureconnoisseur/binge), feature-matched and reading from the same Stash GraphQL API. SwiftUI + AVKit, iOS 17+.

---

## Highlights

- **Vertical reel** — paged swipe, double-tap-to-like, hold-to-pause, action stack (heart, rate, scribe, save, ⋯).
- **Home** — IG-style stories row (library + StashDB + optional Reddit) over a scene feed. Bulk imports collapse into single pack cards.
- **Explore + Following + Saved** — search, Discover Performers row, favourited list, collections (3-column grid each).
- **Performer profiles** — bio, social links, stats, scene grid. Library and StashDB-only variants share the layout.
- **StashDB discovery** — DISCOVER + TRENDING cards in Home; one-tap Follow + Add scene to library.
- **Native swipe-back** everywhere — interactive pop gesture from the left edge, slide-from-right push transitions.

---

## What it does

> Screenshots are **demo-mode** captures — fictional names + placeholder visuals, nothing real. The StashDB discovery surfaces (Follow/Add, Discover row) need live data and aren't pictured.

### Reel · For You

<img align="right" width="250" src="screenshots/reel.png" alt="Vertical reel with the action stack" />

Paged vertical swipe through scenes — double-tap to like, hold to pause, swipe to advance. The right-side action stack carries heart, rate, scribe, save, and ⋯; filter chips at the top constrain the feed by performer / tag / studio and persist as you scroll. Subtle haptics fire on like, page-snap, favourite, save, and rating.

<br clear="all" />

### Home

<img align="right" width="250" src="screenshots/home.png" alt="Home — stories row over a scene feed with a pack card" />

An IG-style **stories row** of performers with fresh content (library scenes within your lookback, plus StashDB new releases and Reddit posts when binge-server is reachable) sits over a **scene feed** of cards: preview video, performer header, title + expandable description + tags. Bulk imports of one performer collapse into a single **pack card** with a mosaic, so one prolific performer doesn't flood the feed. Tap a bubble → the story viewer auto-plays and lets you flick across performers.

<br clear="all" />

<p align="center"><img width="250" src="screenshots/story.png" alt="Story viewer — performer carousel + progress strip" /></p>

### Explore

<img align="right" width="250" src="screenshots/explore.png" alt="Explore — tag chips over a scene grid" />

A search bar, recency-scored tag chips from your interaction history, and a 3-column scene grid. A **Discover Performers** row scrolls StashDB's recent-activity performers (filtered to your enabled genders). Tap a chip to refilter, a tile to drop into a chained reel, or a performer to open their profile.

<br clear="all" />

### Following · Saved

<img align="right" width="250" src="screenshots/following.png" alt="Following — favourites + all performers" />

**Following** splits every performer in your library into Favourites + All, with name / scene-count sorting and search. **Saved** holds your collections (Favourite ★, Watch Later, and any custom ones); each opens a scene grid, and the reel's bookmark drops a scene into any of them.

<br clear="all" />

<p align="center"><img width="250" src="screenshots/saved.png" alt="Saved — collections with cover mosaics" /></p>

### Performer profile

<img align="right" width="250" src="screenshots/profile.png" alt="Performer profile — stats, links, scene grid" />

A full-screen profile: avatar (with the pink→purple→blue story ring on new content), bio, stats, social-link row, a Favourite/Follow action, and Scenes + Photos tabs. Library and StashDB-only variants share the layout; the latter swaps in a Follow action and a scrape sheet.

<br clear="all" />

---

## Install

You need a Stash server. The app talks to its GraphQL API.

```bash
git clone https://github.com/ordureconnoisseur/binge-ios.git
cd binge-ios
brew install xcodegen
xcodegen
open binge.xcodeproj
```

In Xcode: **Signing → your Apple ID**, plug in your iPhone, ⌘R.

A free Apple ID works for personal sideload (7-day expiry, your own devices). A paid Developer account unlocks TestFlight + longer install windows.

### First launch

Paste your Stash URL, then either:

- **API key** — Stash → Settings → Security → API Key, paste it.
- **Sign in** — username + password; binge fetches your API key automatically (no key rotation).

Credentials are stored in the iOS Keychain.

---

## Companion plugin integrations

Detected at runtime — install whichever you want; binge degrades gracefully when they're absent.

| Plugin | What it adds |
|-|-|
| [stash-advanced-rating](https://github.com/ordureconnoisseur/stash-advanced-rating) | Per-criterion 0–5 rating modal in reel + performer profile |
| [stash-scribe](https://github.com/ordureconnoisseur/stash-scribe) | Scribe pencil icon → LLM-powered review writing |
| [binge-server](https://github.com/ordureconnoisseur/binge-server) | Reddit posts in the stories row |

---

## Library prep (optional)

AVPlayer struggles with some codecs over remote Stash connections. Two helper scripts handle the common issues:

- **`scripts/convert-vp9.sh <path>`** — re-encodes VP9 to H.264 in place (atomic tmp + rename, libx264 veryfast / CRF 23). For Instagram-shaped libraries.
- **`scripts/fix-hevc-tag.sh <path>`** — rewrites HEVC `hev1` codec tag to `hvc1` + `+faststart`. No re-encoding, seconds per file. Resolves most AVPlayer-HEVC autoplay quirks.

Both walk the tree, ffprobe each file, only touch what matches.

---

## Settings

**Menu → Settings.** All preferences stored locally.

| Setting | Default | Notes |
|-|-|-|
| Stash connection | — | URL + API key (or sign-in) |
| Genders to surface | All | Drives Discover row + stories |
| Stream type | Auto | Auto / Direct / MP4 / HLS / WebM |
| Recent window | 30 days | How far back "new" means for stories + feed |
| Include StashDB new releases | On | In stories + Home |
| Mix StashDB into profiles | Off | Also flip-able per-profile from the scenes-heading pill |
| Include Reddit posts | On | Requires binge-server reachable |
| binge-server URL | `http://localhost:7878` | Override if remote |
| Auto-scroll | Off | Advance to next scene when current ends |

---

## Architecture

- **SwiftUI + AVKit + AVFoundation**, iOS 17+ for `.scrollPosition(id:)` paging and the Observation framework.
- **`StashClient.gql<T>`** — single async-throws GraphQL function, mirrors the web's `graphql.ts`.
- **`PlayerPool`** — capacity-3 LRU of `AVQueuePlayer` + `AVPlayerLooper`. N+1 prewarm. Buffer tuned for first-frame speed over Tailscale-style links.
- **`KeychainStore`** — `@Observable` singleton wrapping Security framework. Auto-migrates from UserDefaults on first launch.
- **NavigationStack push** for every drilled-in destination — reels, performer profiles, collection grids. Native edge-swipe pop everywhere.
- **No build-time plugin coupling** — `PluginContext` queries Stash's `plugins { id enabled }` at boot; features gate via SwiftUI environment.

---

## Development

```bash
xcodegen   # regen project after adding files or editing project.yml
xcodebuild -scheme binge -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO build   # CI-style compile check
```

Project file (`binge.xcodeproj`) is checked in but regenerated by XcodeGen — run `xcodegen` after adding source files.

---

## License

AGPL-3.0. See [LICENSE](./LICENSE). (Matches Stash's own license.)
