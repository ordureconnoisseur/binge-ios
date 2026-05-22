import SwiftUI

// Settings screen — serves two duties:
//   - `.setup` mode: first-launch entry; the user pastes their
//     Stash URL + API key and hits Connect. On a successful probe
//     the creds are persisted and RootView re-renders into the
//     main shell.
//   - `.normal` mode: visible as a tab inside the main shell after
//     setup. Same fields, but no "blocking" full-screen vibe — the
//     user can edit creds + read other configuration there.
struct SettingsView: View {
    enum Mode { case setup, normal }
    let mode: Mode

    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""

    // Local draft state — we don't write the @AppStorage values
    // until "Connect" succeeds, so a half-typed URL never poisons
    // RootView's branch.
    @State private var draftUrl: String = ""
    @State private var draftApiKey: String = ""
    @State private var probeState: ProbeState = .idle

    enum ProbeState: Equatable {
        case idle
        case probing
        case success(String) // stash version
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
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
                        "Stash → Settings → Security → API Key. Paste here. The URL is whatever you type into your browser to reach Stash — usually your home server's LAN IP."
                    )
                }

                Section {
                    Button {
                        Task { await runProbe() }
                    } label: {
                        HStack {
                            if probeState == .probing {
                                ProgressView()
                                    .padding(.trailing, 4)
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
            .navigationTitle(mode == .setup ? "Set up binge" : "Settings")
            .onAppear {
                // Pre-fill drafts from persisted values so editing
                // in `.normal` mode shows what's currently saved.
                if draftUrl.isEmpty { draftUrl = stashUrl }
                if draftApiKey.isEmpty { draftApiKey = stashApiKey }
            }
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
            // Persist on success — RootView's @AppStorage observers
            // pick this up and switch into the main shell.
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

#Preview("Setup") {
    SettingsView(mode: .setup)
}

#Preview("Normal") {
    SettingsView(mode: .normal)
}
