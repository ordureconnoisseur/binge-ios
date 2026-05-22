# binge-ios

Native iOS port of [the binge Stash plugin](https://github.com/ordureconnoisseur/binge).
SwiftUI + AVKit; targets iOS 17+.

**Status**: v0.1 — week 1 of 6. Scaffolding only. Can connect to a
Stash instance and validate creds; no reel / home / profile yet.

---

## Why a native port

The web plugin renders fine on mobile Safari, but two specific things
hit a wall:

1. **Reel paging smoothness** — scroll-snap + `<video>` on iOS Safari
   has occasional micro-jitters that `TabView(.page)` + `AVPlayer`
   don't.
2. **Concurrent video decoders** — Safari hard-limits decoder count
   tighter than `AVPlayer`'s pool, so the prefetch-3-ahead pattern
   chokes on iOS when scrolling fast.

If you're on desktop or web is "good enough" for you, the original
plugin is the right choice. This port is for people who want it to
feel like a Swift app, because it is one.

---

## Setup

You need an Apple ID. The free tier is enough for personal sideload
(7-day expiry, your own devices only). A paid Apple Developer
account ($99/year) unlocks TestFlight + App Store but is not needed
for v0.1.

```bash
# 1. Clone
git clone https://github.com/ordureconnoisseur/binge-ios.git
cd binge-ios

# 2. Install XcodeGen if you don't have it
brew install xcodegen

# 3. Generate the .xcodeproj (run this any time you add a Swift file
#    so the project is in sync; or when project.yml changes)
xcodegen

# 4. Open in Xcode
open binge.xcodeproj
```

In Xcode:

1. **Signing & Capabilities → Team → your personal Apple ID**
2. Connect your iPhone via cable, select it as the run destination
3. Press ⌘R

On first launch, paste your Stash URL + API key into the setup
screen, hit Connect. After that, the main shell appears (TabView
stub for now).

---

## Architecture

```
binge-ios/
├── project.yml                         # XcodeGen manifest
├── binge.xcodeproj/                    # Generated, gitignored after v0.1
├── binge/
│   ├── bingeApp.swift                  # @main entry
│   ├── RootView.swift                  # Setup-vs-main shell branch
│   ├── Models/                         # struct Scene / Performer / Tag
│   ├── Services/
│   │   ├── StashClient.swift           # actor; gql<T>(query, vars)
│   │   ├── Queries.swift               # GraphQL query strings
│   │   └── VideoPlayerPool.swift       # (week 2) AVPlayer reuse
│   └── Views/
│       ├── Reel/                       # (week 2) TabView(.page) + AVPlayer
│       ├── Home/                       # (week 3) stories + feed
│       ├── Performer/                  # (week 4) profile + scene grid
│       └── Settings/SettingsView.swift # First-launch setup + tab
```

### Networking

`StashClient` is an `actor` with one method:

```swift
func gql<T: Decodable>(_ query: String, variables: [String: Any] = [:]) async throws -> T
```

Mirrors the web's `src/api/graphql.ts`. Same `ApiKey` header pattern,
same error semantics. Response shape uses Swift `Codable` structs in
`Models/`.

### State

- `@AppStorage("binge.*")` for persistent settings (Stash URL, API key,
  mute state, transcode preference)
- Per-view `@State` for ephemeral UI
- A global `AppState` `@Observable` class will land in week 2 once
  the reel needs shared state across views

### Reel implementation (incoming, week 2)

- `TabView` with `.tabViewStyle(.page(indexDisplayMode: .never))` for
  vertical paged scrolling
- `AVPlayer` per slide, pooled with a cap of ~4 concurrent decoders
  to mirror the web's prefetch-3-ahead without exceeding iOS's
  hardware-decoder budget
- `AVPlayerLayer` wrapped in `UIViewRepresentable` for SwiftUI

---

## Scope

### In v0.1
- Reel with vertical paging
- Action stack: heart, save (UI-only — backend lands later)
- Home: stories row + scene feed
- Performer profile: bio, scene grid, follow toggle
- Stash auth via URL + API key

### Out of scope for v0.1 (parked for v0.2+)
- Explore tab + chip strip
- Following tab
- Saved collections / SaveSheet
- ASR/APR criterion-rating modal
- Reddit / binge-server integration
- StashDB integration
- Refract palette mirroring
- iPad / landscape
- Light mode
- App Store / TestFlight submission

---

## License

MIT. See [LICENSE](./LICENSE).
