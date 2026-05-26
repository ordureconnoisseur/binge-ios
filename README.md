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

<!-- TODO: 01-hero — reel slide in action (video/GIF, 9:16, vertical phone frame). The signature shot. -->

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

<!-- TODO: 02-welcome — welcome screen, gradient infinity hero -->
<!-- TODO: 03-signin — welcome screen with the Sign-in tab active -->

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
| Showcase mode | On | Apply a Stash filter named "Showcase" to For You — safe demos. No-op if the filter doesn't exist. |
| Genders to surface | Female + Trans female | Drives Discover row + stories |
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

MIT. See [LICENSE](./LICENSE).

<!-- Screenshot placeholders — uncomment as each lands.
     Upload via gh release upload media-assets <file> --repo ordureconnoisseur/binge-ios
     Stable URL: github.com/ordureconnoisseur/binge-ios/releases/download/media-assets/<file>

     Capture targets: dark mode, iPhone 17 Pro (1206×2622), latest sim.

     01-hero            Reel slide in action (GIF/MP4, 9:16, phone frame)
     02-welcome         Welcome screen with gradient infinity hero
     03-signin          Welcome screen with Sign-in tab active
     04-home            Stories row + scene feed cards
     05-reel            Reel mid-playback with action stack
     06-profile         Performer profile with social-link row
     07-explore         Explore page (Discover bar + chips + grid)
     08-saved-grid      Collection detail page (3-column grid)
     09-discovery-card  Single discovery card with avatar stack + Follow
-->
