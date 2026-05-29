import SwiftUI

// Settings screen — serves two duties:
//   - `.setup` mode: first-launch entry; user pastes their Stash
//     URL + API key and hits Connect. On a successful probe the
//     creds are persisted and RootView re-renders into the main
//     shell.
//   - `.normal` mode: pushed from MenuPage. Same connection
//     section + multiple preference sections (streaming, reel,
//     home, debug).
//
// Iconography deliberately uses system Form / Section / Picker /
// Toggle so the screen reads as native iOS settings; the rest of
// the app is custom-themed but settings benefits from system
// familiarity.
struct SettingsView: View {
    enum Mode { case setup, normal }
    let mode: Mode

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    // Stash API key lives in Keychain, not UserDefaults — see
    // KeychainStore. Computed get/set forwards to the singleton so
    // existing read/write call sites (draftApiKey hydration on
    // line 64, save on line 381) stay unchanged.
    private var stashApiKey: String {
        get { KeychainStore.shared.stashApiKey }
        nonmutating set { KeychainStore.shared.stashApiKey = newValue }
    }

    // Streaming / reel / home preferences. Defaults match the
    // hardcoded behavior the app shipped with before these became
    // user-tunable, so existing users see no change on first run.
    @AppStorage("binge.transcodeType") private var transcodeType: String = "auto"
    @AppStorage("binge.autoScroll") private var autoScroll: Bool = false
    @AppStorage("binge.lookbackDays") private var lookbackDays: Int = 30
    @AppStorage("binge.includeStashDB") private var includeStashDB: Bool = true
    @AppStorage("binge.includeReddit") private var includeReddit: Bool = true
    @AppStorage("binge.bingeServerUrl") private var bingeServerUrl: String = ""
    @AppStorage("binge.showDebug") private var showDebug: Bool = false

    // Local draft state for the connection fields — we only write
    // the @AppStorage values when a probe succeeds, so a half-typed
    // URL never poisons RootView's branch.
    @State private var draftUrl: String = ""
    @State private var draftApiKey: String = ""
    @State private var probeState: ProbeState = .idle

    // Username+password sign-in path (welcome screen only). Fetches
    // the API key automatically via StashLoginService, then hands
    // off to the existing `runProbe()` for the final validate +
    // persist step.
    @State private var authMethod: AuthMethod = .apiKey
    @State private var draftUsername: String = ""
    @State private var draftPassword: String = ""

    enum AuthMethod: Hashable {
        case apiKey
        case signIn
    }

    enum ProbeState: Equatable {
        case idle, probing
        case success(String) // stash version
        case failure(String)
    }

    var body: some View {
        // .setup mode: custom welcome chrome. First impression for
        // anyone who isn't the person who built the app, so it
        // explains what binge is + what they need before dropping
        // them into form fields. The connection probe / persist
        // path is identical to .normal mode (`runProbe()`).
        //
        // .normal mode: pushed from MenuPage with full settings
        // surface (preferences, debug, binge-server config).
        if mode == .setup {
            NavigationStack {
                welcomeBody
            }
        } else {
            normalBody
        }
    }

    // MARK: - .normal body (existing form)

    @ViewBuilder
    private var normalBody: some View {
        Form {
            connectionSection
            gendersSection
            streamingSection
            reelSection
            homeSection
            bingeServerSection
            bingeServerConfigSection
            debugSection
        }
        .onAppear {
            if draftUrl.isEmpty { draftUrl = stashUrl }
            if draftApiKey.isEmpty { draftApiKey = stashApiKey }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - .setup body (welcome + inline connection)

    @ViewBuilder
    private var welcomeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcomeHero
                welcomeRequirements
                welcomeConnectionForm
                welcomeProbeFeedback
                welcomeOptionalNotes
            }
            .padding(.horizontal, 22)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if draftUrl.isEmpty { draftUrl = stashUrl }
            if draftApiKey.isEmpty { draftApiKey = stashApiKey }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var welcomeHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Welcome-screen-only: gradient version of the brand
            // mark (pink→purple→blue, same palette as the story
            // ring used in the rest of the app + on the web).
            // The monochrome BingeLogoMark stays in the toolbars
            // where chrome is meant to be quiet.
            Image("BingeLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 56)
                .foregroundStyle(LinearGradient.bingeStoryRing)
                .accessibilityLabel("binge")
            Text("Welcome to binge")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text(
                "A native iOS client for your Stash library — "
                + "reels, stories, performer profiles, ratings, "
                + "and collections, all reading from the server "
                + "you already run."
            )
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var welcomeRequirements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You'll need")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(0.5)
            requirementRow(
                icon: "server.rack",
                title: "Your Stash server's address",
                detail: "e.g. http://192.168.1.100:9999 — "
                    + "or a Tailscale/VPN URL if you reach "
                    + "Stash from outside your LAN."
            )
            requirementRow(
                icon: "key.fill",
                title: "A way to sign in",
                detail: "Either a Stash API key "
                    + "(Settings → Security in Stash), "
                    + "or your username + password if "
                    + "Stash has accounts enabled — "
                    + "binge can fetch the key for you."
            )
        }
    }

    @ViewBuilder
    private func requirementRow(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var welcomeConnectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash connection")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(0.5)

            TextField(
                "",
                text: $draftUrl,
                prompt: Text("http://192.168.1.100:9999")
                    .foregroundStyle(.white.opacity(0.35))
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )

            // Auth method picker. API-key path is the default
            // (broadest compatibility). Sign-in path uses
            // StashLoginService to fetch the key for the user.
            Picker("", selection: $authMethod) {
                Text("API key").tag(AuthMethod.apiKey)
                Text("Sign in").tag(AuthMethod.signIn)
            }
            .pickerStyle(.segmented)

            if authMethod == .apiKey {
                SecureField(
                    "",
                    text: $draftApiKey,
                    prompt: Text("API key")
                        .foregroundStyle(.white.opacity(0.35))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                )
            } else {
                TextField(
                    "",
                    text: $draftUsername,
                    prompt: Text("Username")
                        .foregroundStyle(.white.opacity(0.35))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                )

                SecureField(
                    "",
                    text: $draftPassword,
                    prompt: Text("Password")
                        .foregroundStyle(.white.opacity(0.35))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                )
            }

            Button {
                Task { await runWelcomeConnect() }
            } label: {
                HStack(spacing: 8) {
                    if probeState == .probing {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(connectButtonText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(canConnect ? Color.bingeLike : Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConnect)
            .padding(.top, 4)
        }
    }

    private var canConnect: Bool {
        guard probeState != .probing, !draftUrl.isEmpty else {
            return false
        }
        switch authMethod {
        case .apiKey:
            return !draftApiKey.isEmpty
        case .signIn:
            return !draftUsername.isEmpty && !draftPassword.isEmpty
        }
    }

    private var connectButtonText: String {
        if probeState == .probing {
            return authMethod == .signIn
                ? "Signing in…"
                : "Connecting…"
        }
        return authMethod == .signIn
            ? "Sign in"
            : "Test connection"
    }

    /// Welcome-screen entry point. For API-key auth, falls through
    /// directly to `runProbe()`. For sign-in auth, fetches the API
    /// key from Stash first via StashLoginService, populates
    /// `draftApiKey`, then calls `runProbe()` so the final
    /// validate-and-persist step is shared with the manual path.
    @MainActor
    private func runWelcomeConnect() async {
        if authMethod == .signIn {
            probeState = .probing
            do {
                let key = try await StashLoginService.fetchApiKey(
                    baseURL: draftUrl,
                    username: draftUsername,
                    password: draftPassword
                )
                draftApiKey = key
                // Fall through to runProbe — same validate-and-
                // persist path the manual-paste flow uses.
            } catch let err as StashLoginError {
                probeState = .failure(
                    err.errorDescription ?? "Sign-in failed."
                )
                return
            } catch {
                probeState = .failure(error.localizedDescription)
                return
            }
        }
        await runProbe()
    }

    @ViewBuilder
    private var welcomeProbeFeedback: some View {
        switch probeState {
        case .idle, .probing:
            EmptyView()
        case .success(let v):
            Label(
                "Connected · Stash \(v)",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.green)
        case .failure(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Couldn't connect",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.red.opacity(0.12))
            )
        }
    }

    @ViewBuilder
    private var welcomeOptionalNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional features")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(0.5)
            optionalRow(
                icon: "star.fill",
                title: "Advanced Rating plugin",
                detail: "Per-criterion 0–5 scoring. "
                    + "binge falls back to basic ratings if absent."
            )
            optionalRow(
                icon: "text.bubble.fill",
                title: "Stash Scribe plugin",
                detail: "LLM-powered review writing. "
                    + "Scribe button hides if not installed."
            )
            optionalRow(
                icon: "antenna.radiowaves.left.and.right",
                title: "binge-server",
                detail: "Self-hosted Go daemon that pulls "
                    + "Reddit posts into the stories row. "
                    + "Configure later under Settings."
            )
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func optionalRow(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            TextField(
                "http://192.168.1.100:9999",
                text: $draftUrl
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            SecureField("API key", text: $draftApiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Stash connection")
        } footer: {
            Text(
                "Stash → Settings → Security → API Key. Paste here. "
                    + "The URL is whatever you type into your browser "
                    + "to reach Stash — usually your home server's LAN IP."
            )
        }

        Section {
            Button {
                Task { await runProbe() }
            } label: {
                HStack {
                    if probeState == .probing {
                        ProgressView().padding(.trailing, 4)
                    }
                    Text(connectButtonLabel)
                }
            }
            .disabled(
                draftUrl.isEmpty || draftApiKey.isEmpty
                    || probeState == .probing
            )

            switch probeState {
            case .idle, .probing:
                EmptyView()
            case .success(let v):
                Label(
                    "Connected · Stash \(v)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .failure(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Genders

    /// Bound directly to the same UserDefaults key
    /// AllowedGendersStore uses. The string ↔ Set conversion lives
    /// in the section body so toggles re-render on @AppStorage
    /// updates (the raw String is what triggers SwiftUI's diff).
    @AppStorage(AllowedGendersStore.storageKey)
    private var allowedGendersRaw: String = "FEMALE,TRANSGENDER_FEMALE"


    @ViewBuilder
    private var gendersSection: some View {
        Section {
            let active = parsedAllowedGenders(allowedGendersRaw)
            HStack(spacing: 10) {
                ForEach(AllowedGender.allCases) { g in
                    Button {
                        var next = active
                        if next.contains(g) { next.remove(g) }
                        else { next.insert(g) }
                        AllowedGendersStore.write(next)
                    } label: {
                        GenderIconShape(gender: g)
                            .stroke(
                                active.contains(g)
                                    ? Color.white
                                    : Color.white.opacity(0.5),
                                style: StrokeStyle(
                                    lineWidth: 1.8,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                            .frame(width: 24, height: 24)
                            .padding(8)
                            .background(
                                Circle().fill(
                                    active.contains(g)
                                        ? Color.bingeLike
                                        : Color.white.opacity(0.08)
                                )
                            )
                            .overlay(
                                Circle().stroke(
                                    active.contains(g)
                                        ? Color.clear
                                        : Color.white.opacity(0.18),
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(g.label)
                    .accessibilityAddTraits(
                        active.contains(g) ? .isSelected : []
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Genders to surface")
        } footer: {
            Text(
                "Performers of these genders appear on the Home "
                    + "discovery feed and Explore's Discover "
                    + "Performers row."
            )
        }
    }

    /// String → Set decoder. Empty string is honored as "show
    /// nothing" rather than reverting to the default — matches
    /// AllowedGendersStore.current() and the web's read semantics.
    private func parsedAllowedGenders(
        _ raw: String
    ) -> Set<AllowedGender> {
        // Special-case the legacy "never written" state: a fresh
        // @AppStorage default uses the supplied initialValue, so
        // first-render raw will be the literal default
        // "FEMALE,TRANSGENDER_FEMALE". After any write the raw is
        // authoritative. No extra handling needed beyond parsing.
        Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .compactMap(AllowedGender.init(rawValue:))
        )
    }

    // MARK: - Streaming

    @ViewBuilder
    private var streamingSection: some View {
        Section {
            Picker("Stream type", selection: $transcodeType) {
                Text("Auto (Stash decides)").tag("auto")
                Text("Direct (no transcode)").tag("direct")
                Text("Transcoded MP4").tag("mp4")
                Text("HLS streaming").tag("hls")
                Text("Transcoded WebM").tag("webm")
            }
        } header: {
            Text("Streaming")
        } footer: {
            Text(
                "Auto follows Stash's transcode rules — HEVC content "
                    + "routes via HLS, everything else plays direct. "
                    + "Force a specific type if you see playback "
                    + "issues with the default."
            )
        }
    }

    // MARK: - Reel

    @ViewBuilder
    private var reelSection: some View {
        Section {
            Toggle("Auto-scroll", isOn: $autoScroll)
        } header: {
            Text("Reel")
        } footer: {
            Text(
                "Advance to the next scene automatically when the "
                    + "current one finishes."
            )
        }
    }

    // MARK: - Home

    @ViewBuilder
    private var homeSection: some View {
        Section {
            // Capped at 90: the Home feed fetches the whole window at
            // once, so the window size bounds the fetch.
            Picker("Lookback", selection: $lookbackDays) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
            }
            Toggle("Discover from StashDB", isOn: $includeStashDB)
            Toggle("Discover from Reddit", isOn: $includeReddit)
        } header: {
            Text("Home")
        } footer: {
            Text(
                "Lookback controls how far back the stories row + "
                    + "home feed look for recent activity. "
                    + "StashDB discovery surfaces new scenes from "
                    + "stashdb.org for performers in your library "
                    + "(needs a stashbox API key configured in "
                    + "Stash). Reddit discovery pulls posts from "
                    + "performers' configured reddit URLs via "
                    + "binge-server (configure below)."
            )
        }
    }

    // MARK: - binge-server URL

    @ViewBuilder
    private var bingeServerSection: some View {
        Section {
            HStack {
                TextField(
                    BingeServerService.defaultURL,
                    text: $bingeServerUrl
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                BingeServerHealthDot()
            }
        } header: {
            Text("binge-server URL")
        } footer: {
            Text(
                "HTTP address of the binge-server daemon. Default "
                    + "is \(BingeServerService.defaultURL) — change "
                    + "this if you run the daemon on a different "
                    + "host or port. The status dot pings /healthz."
            )
        }
    }

    // MARK: - binge-server config card

    @ViewBuilder
    private var bingeServerConfigSection: some View {
        BingeServerConfigCard()
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        Section {
            Toggle("Show debug overlay", isOn: $showDebug)
        } header: {
            Text("Debug")
        } footer: {
            Text(
                "Surfaces scene IDs + state diagnostics on top of the "
                    + "reel. Useful when reporting issues."
            )
        }
    }

    private var connectButtonLabel: String {
        switch mode {
        case .setup: return "Connect"
        case .normal: return "Save and re-test"
        }
    }

    @MainActor
    private func runProbe() async {
        probeState = .probing
        let client = StashClient(baseURL: draftUrl, apiKey: draftApiKey)
        do {
            let resp: VersionResponse = try await client.gql(Queries.version)
            probeState = .success(resp.version.version)
            stashUrl = draftUrl.trimmingCharacters(
                in: CharacterSet(charactersIn: "/ \n\r\t")
            )
            stashApiKey = draftApiKey
        } catch {
            probeState = .failure(
                (error as? LocalizedError)?.errorDescription
                    ?? "\(error)"
            )
        }
    }
}

// Path-based gender glyphs in a 24×24 box. Same path geometry as
// the web SettingsPage's GenderIcon — so the iOS button visuals
// match the web toggle visuals one-to-one. Stroke colour is
// driven by the parent's `.stroke(...)` call so the active /
// inactive states inherit the toggle button's chrome.
struct GenderIconShape: Shape {
    let gender: AllowedGender

    func path(in rect: CGRect) -> Path {
        // The shape was authored on a 24×24 canvas. Build the
        // path there, then scale it to fit `rect`. This keeps
        // the coordinates readable AND lets callers pass any
        // frame size without coordinate rewrites.
        let path = Path { p in
            switch gender {
            case .female:
                p.addEllipse(in: CGRect(x: 7.5, y: 4.5, width: 9, height: 9))
                p.move(to: CGPoint(x: 12, y: 13.5))
                p.addLine(to: CGPoint(x: 12, y: 20.5))
                p.move(to: CGPoint(x: 9, y: 17.5))
                p.addLine(to: CGPoint(x: 15, y: 17.5))
            case .male:
                p.addEllipse(in: CGRect(x: 5.5, y: 9.5, width: 9, height: 9))
                p.move(to: CGPoint(x: 13.2, y: 10.8))
                p.addLine(to: CGPoint(x: 20, y: 4))
                p.move(to: CGPoint(x: 14, y: 4))
                p.addLine(to: CGPoint(x: 20, y: 4))
                p.addLine(to: CGPoint(x: 20, y: 10))
            case .transgenderFemale:
                // Venus body shifted slightly up to make room for
                // the trans-modifier arrow off the upper-left.
                p.addEllipse(in: CGRect(x: 8, y: 7, width: 8, height: 8))
                p.move(to: CGPoint(x: 12, y: 15))
                p.addLine(to: CGPoint(x: 12, y: 21))
                p.move(to: CGPoint(x: 9.5, y: 18.5))
                p.addLine(to: CGPoint(x: 14.5, y: 18.5))
                // Upper-left arrow extension (the trans modifier).
                p.move(to: CGPoint(x: 9.1, y: 8.1))
                p.addLine(to: CGPoint(x: 5, y: 4))
                p.move(to: CGPoint(x: 5, y: 4))
                p.addLine(to: CGPoint(x: 8.5, y: 4))
                p.move(to: CGPoint(x: 5, y: 4))
                p.addLine(to: CGPoint(x: 5, y: 7.5))
            case .transgenderMale:
                // Mars body + a perpendicular strikethrough across
                // the diagonal arrow shaft — mirrors U+26A6.
                p.addEllipse(in: CGRect(x: 6, y: 10, width: 8, height: 8))
                p.move(to: CGPoint(x: 12.8, y: 11.2))
                p.addLine(to: CGPoint(x: 20, y: 4))
                p.move(to: CGPoint(x: 14, y: 4))
                p.addLine(to: CGPoint(x: 20, y: 4))
                p.addLine(to: CGPoint(x: 20, y: 10))
                p.move(to: CGPoint(x: 14.5, y: 9.5))
                p.addLine(to: CGPoint(x: 17.5, y: 12.5))
            case .nonBinary:
                // Circle with bare vertical stems above and below.
                p.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
                p.move(to: CGPoint(x: 12, y: 3))
                p.addLine(to: CGPoint(x: 12, y: 8))
                p.move(to: CGPoint(x: 12, y: 16))
                p.addLine(to: CGPoint(x: 12, y: 21))
            }
        }
        // Scale & translate the 24×24 path into the requested rect.
        let sx = rect.width / 24
        let sy = rect.height / 24
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: sx, y: sy)
        )
    }
}

// MARK: - binge-server health + config

/// Small status dot beside the URL field — green when /healthz
/// returns ok, red on any failure, yellow while the probe is in
/// flight. Re-probes whenever the bound URL changes.
private struct BingeServerHealthDot: View {
    @AppStorage("binge.bingeServerUrl") private var url: String = ""
    @State private var state: Probe = .pending

    enum Probe { case pending, ok, down }

    var body: some View {
        Circle()
            .fill(colorForState)
            .frame(width: 8, height: 8)
            .accessibilityLabel(labelForState)
            .task(id: url) { await probe() }
    }

    private var colorForState: Color {
        switch state {
        case .pending: return .yellow
        case .ok: return .green
        case .down: return .red
        }
    }

    private var labelForState: String {
        switch state {
        case .pending: return "binge-server status pending"
        case .ok: return "binge-server reachable"
        case .down: return "binge-server unreachable"
        }
    }

    private func probe() async {
        state = .pending
        let h = await BingeServerService.health()
        state = (h?.ok == true) ? .ok : .down
    }
}

/// Settings card mirroring the web's `BingeServerConfigCard` —
/// auto-pushes the Stash API key on first reach (silent), and
/// lets the user paste the Reddit session cookie. Shows
/// per-credential state so the user can confirm both pieces are
/// in place before expecting Reddit posts to surface.
private struct BingeServerConfigCard: View {
    @AppStorage("binge.bingeServerUrl") private var url: String = ""
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    // Read-only on this card; full get/set lives in the main
    // SettingsView struct above.
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var config: BingeServerConfigState?
    @State private var probing: Bool = true
    @State private var cookieInput: String = ""
    @State private var cookieBusy: Bool = false
    @State private var cookieError: String?
    @State private var cookieSaved: Bool = false
    @State private var showHelp: Bool = false

    var body: some View {
        Section {
            if probing && config == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Probing binge-server…")
                        .foregroundStyle(.secondary)
                }
            } else if config == nil {
                Label(
                    "binge-server unreachable",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            } else if let c = config {
                stashKeyRow(c)
                redditCookieRow(c)
                Button(
                    showHelp
                        ? "Hide cookie help"
                        : "How to get the Reddit cookie"
                ) {
                    showHelp.toggle()
                }
                if showHelp {
                    cookieHelp
                }
            }
        } header: {
            Text("binge-server configuration")
        } footer: {
            Text(
                "Daemon needs your Stash API key (auto-pushed on "
                    + "first connect) and a Reddit session cookie "
                    + "(paste below). Without the cookie no Reddit "
                    + "posts will be fetched."
            )
        }
        .task(id: url) { await refresh() }
        .task(id: config?.stashApiKeySet ?? false) {
            await maybePushStashKey()
        }
    }

    @ViewBuilder
    private func stashKeyRow(_ c: BingeServerConfigState) -> some View {
        HStack {
            Label(
                "Stash API key",
                systemImage: c.stashApiKeySet
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle"
            )
            .foregroundStyle(c.stashApiKeySet ? .green : .orange)
            Spacer()
            Text(c.stashApiKeySet ? "Set" : "Pushing…")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func redditCookieRow(_ c: BingeServerConfigState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "Reddit cookie",
                    systemImage: c.redditCookieSet
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle"
                )
                .foregroundStyle(c.redditCookieSet ? .green : .orange)
                Spacer()
                Text(c.redditCookieSet ? "Set" : "Not set")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            SecureField(
                c.redditCookieSet
                    ? "Paste new cookie to rotate…"
                    : "Paste reddit_session value here",
                text: $cookieInput
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            HStack {
                Button {
                    Task { await saveCookie() }
                } label: {
                    if cookieBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(c.redditCookieSet ? "Rotate" : "Save")
                    }
                }
                .disabled(
                    cookieBusy
                        || cookieInput.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
                if cookieSaved {
                    Label("Saved", systemImage: "checkmark")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
                if let err = cookieError {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var cookieHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "1. Open reddit.com in a desktop browser, logged "
                    + "in."
            )
            Text(
                "2. DevTools → Application → Cookies → "
                    + "https://www.reddit.com"
            )
            Text(
                "3. Find `reddit_session` — copy the entire Value "
                    + "string."
            )
            Text(
                "4. Paste it above and tap Save. The daemon "
                    + "validates against /api/me.json before "
                    + "persisting; an invalid cookie surfaces an "
                    + "error here."
            )
            Text(
                "Cookies expire every few months — when Reddit "
                    + "stops surfacing you'll need to rotate."
            )
            .padding(.top, 4)
            .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private func refresh() async {
        probing = true
        config = await BingeServerService.config()
        probing = false
    }

    /// Auto-push the Stash API key on first reach when the
    /// daemon doesn't have one. Mirrors web's silent-push effect
    /// — the user never sees this step succeed; failure surfaces
    /// as the Stash-API-key row staying in the "Pushing…" state.
    private func maybePushStashKey() async {
        guard let c = config else { return }
        if c.stashApiKeySet { return }
        if stashApiKey.isEmpty || stashUrl.isEmpty { return }
        let result = await BingeServerService.setConfig(
            BingeServerConfigPayload(
                stashUrl: stashUrl,
                stashApiKey: stashApiKey,
                redditSessionCookie: nil
            )
        )
        if case .ok = result {
            config = await BingeServerService.config()
        }
    }

    private func saveCookie() async {
        let trimmed = cookieInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.isEmpty { return }
        cookieBusy = true
        cookieError = nil
        cookieSaved = false
        let result = await BingeServerService.setConfig(
            BingeServerConfigPayload(
                stashUrl: nil,
                stashApiKey: nil,
                redditSessionCookie: trimmed
            )
        )
        switch result {
        case .ok:
            cookieSaved = true
            cookieInput = ""
            config = await BingeServerService.config()
        case .failure(let msg):
            cookieError = msg
        }
        cookieBusy = false
    }
}

#Preview("Setup") {
    SettingsView(mode: .setup)
}

#Preview("Normal") {
    SettingsView(mode: .normal)
}
