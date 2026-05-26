import SwiftUI

// Stash Scribe — multi-phase modal that drives an LLM-assisted
// review writer. Direct port of web's ScribeModal.tsx.
//
// Phases:
//   .loading — subject + config fetch in flight
//   .intro   — fresh subject (no review, no session); pick voice
//              + "Write manually" or "Start LLM interview"
//   .interview — chat transcript + input box; "Send" / "Generate"
//   .result  — editable review textarea + per-criterion sliders;
//              "Save review only" / "Save review + scores"
//   .error   — fatal load failure with retry path
//
// Save points:
//   - After each user message + LLM reply (interview phase)
//   - After Generate produces a result
//   - Cleared on: Start over, successful save
@MainActor
struct ScribeModal: View {
    let subjectRef: SubjectRef

    @Environment(\.dismiss) private var dismiss
    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    @AppStorage("binge.stashApiKey") private var apiKey: String = ""
    @AppStorage("binge.scribe.voice") private var voiceRaw: String =
        VoiceMode.filthy.rawValue

    @State private var phase: Phase = .loading
    @State private var loaded: LoadedState?
    @State private var errorText: String?
    @State private var tone: VoiceMode = .filthy
    @State private var messages: [LLMMessage] = []
    @State private var userInput: String = ""
    @State private var busy: Bool = false
    @State private var busyMsg: String = ""
    @State private var reviewText: String = ""
    @State private var scores: [String: Int] = [:]
    @State private var editMode: Bool = false
    /// Trigger for "scroll transcript to bottom" — bumped on
    /// every message append.
    @State private var transcriptTick: Int = 0
    @State private var confirmRestart: ConfirmKind?

    enum Phase: Hashable {
        case loading, intro, interview, result, error
    }

    struct LoadedState {
        let subject: LoadedSubject
        let config: ScribeConfig
    }

    enum ConfirmKind: Identifiable {
        case startOver
        case backToInterview
        var id: Int {
            switch self {
            case .startOver: return 1
            case .backToInterview: return 2
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.black.ignoresSafeArea())
                .navigationTitle("Stash Scribe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if phase == .interview || phase == .result {
                            Button("Start over") {
                                confirmRestart = .startOver
                            }
                            .foregroundStyle(.white.opacity(0.75))
                            .disabled(busy)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(.white)
                    }
                }
                .toolbarBackground(Color.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task { await load() }
        .confirmationDialog(
            "Restart this interview?",
            isPresented: Binding(
                get: { confirmRestart != nil },
                set: { if !$0 { confirmRestart = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmRestart
        ) { kind in
            Button("Discard and restart", role: .destructive) {
                switch kind {
                case .startOver: startOver()
                case .backToInterview: backToInterviewConfirmed()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your saved reviews on this scene aren't touched.")
        }
    }

    // MARK: - Body content by phase

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            header
            if let err = errorText {
                errorBanner(err)
            }
            switch phase {
            case .loading:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error:
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.red.opacity(0.85))
                    Text(errorText ?? "Failed to load subject")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        dismiss()
                    } label: {
                        Text("Close")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(
                                    Color.white.opacity(0.15)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .intro:
                introContent
            case .interview:
                interviewContent
            case .result:
                resultContent
            }
        }
    }

    // MARK: - Header (context strip)

    @ViewBuilder
    private var header: some View {
        if let strip = loaded?.subject.contextStrip, !strip.isEmpty {
            Text(strip)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Intro phase

    @ViewBuilder
    private var introContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "No review yet for this "
                        + (subjectRef.kind == "performer"
                            ? "performer." : "scene.")
                        + " Pick how you want to write it."
                )
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))

                voicePicker

                VStack(spacing: 10) {
                    Button {
                        startManual()
                    } label: {
                        Text("Write manually")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        Color.white.opacity(0.18),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    Button {
                        startLLMInterview()
                    } label: {
                        HStack(spacing: 6) {
                            if busy {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("Start LLM interview")
                                .font(
                                    .system(size: 15, weight: .semibold)
                                )
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.bingeLike.opacity(0.85))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }

                Text(
                    "LLM mode runs an interview through the Stash "
                        + "Scribe plugin → Ollama. If Ollama is "
                        + "offline, use Write manually — same save "
                        + "target, just no LLM assist."
                )
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VOICE")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.5))
            Picker("Voice", selection: $tone) {
                ForEach(VoiceMode.allCases, id: \.self) { v in
                    Text(v.label).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: tone) { _, new in
                voiceRaw = new.rawValue
            }
        }
    }

    // MARK: - Interview phase

    @ViewBuilder
    private var interviewContent: some View {
        VStack(spacing: 0) {
            transcript
            Divider().background(Color.white.opacity(0.08))
            interviewInput
        }
    }

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleMessages) { m in
                        transcriptBubble(m)
                    }
                    if busy && !busyMsg.isEmpty {
                        Text(busyMsg)
                            .font(.system(size: 12).italic())
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .id("scribe-bottom")
                    } else {
                        Color.clear
                            .frame(height: 1)
                            .id("scribe-bottom")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: transcriptTick) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("scribe-bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Filter out system messages — they bootstrap the persona
    /// but the user doesn't need to read them.
    private var visibleMessages: [LLMMessage] {
        messages.filter { $0.role != .system }
    }

    @ViewBuilder
    private func transcriptBubble(_ m: LLMMessage) -> some View {
        let isUser = m.role == .user
        HStack {
            if isUser { Spacer(minLength: 30) }
            Text(m.content)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            isUser
                                ? Color.bingeLike.opacity(0.55)
                                : Color.white.opacity(0.08)
                        )
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: isUser ? .trailing : .leading
                )
            if !isUser { Spacer(minLength: 30) }
        }
    }

    @ViewBuilder
    private var interviewInput: some View {
        VStack(spacing: 8) {
            TextEditor(text: $userInput)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 100)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .disabled(busy)
                .overlay(alignment: .topLeading) {
                    if userInput.isEmpty {
                        Text("Type your answer…")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.leading, 14)
                            .padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                Button {
                    Task { await sendMessage() }
                } label: {
                    Text("Send")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    busy
                        || userInput.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
                Spacer()
                Button {
                    Task { await generate() }
                } label: {
                    Text("Generate")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(
                                    canGenerate
                                        ? Color.bingeLike.opacity(0.85)
                                        : Color.bingeLike.opacity(0.25)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canGenerate || busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var userExchangeCount: Int {
        messages.filter { $0.role == .user }.count
    }
    private var canGenerate: Bool {
        userExchangeCount >= 1 && !busy
    }

    // MARK: - Result phase

    @ViewBuilder
    private var resultContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("REVIEW")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                TextEditor(text: $reviewText)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                if let crits = loaded?.subject.criteria, !crits.isEmpty {
                    Text("SCORES")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.5))
                    ForEach(crits) { c in
                        scoreRow(c)
                    }
                }
                resultActions
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func scoreRow(_ c: RatingCriterion) -> some View {
        let current = scores[c.id]
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if !c.description.isEmpty {
                    Text(c.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        let newScore: Int? =
                            (current == star) ? nil : star
                        if let v = newScore {
                            scores[c.id] = v
                        } else {
                            scores.removeValue(forKey: c.id)
                        }
                    } label: {
                        Image(
                            systemName: (current ?? 0) >= star
                                ? "star.fill" : "star"
                        )
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            (current ?? 0) >= star
                                ? Color.yellow
                                : Color.white.opacity(0.4)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var resultActions: some View {
        VStack(spacing: 10) {
            if !editMode {
                Button {
                    confirmRestart = .backToInterview
                } label: {
                    Text("Back to interview")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if !busyMsg.isEmpty {
                Text(busyMsg)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 10) {
                Button {
                    Task { await save(withScores: false) }
                } label: {
                    Text("Save review only")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    Color.white.opacity(0.18),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    busy
                        || reviewText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
                Button {
                    Task { await save(withScores: true) }
                } label: {
                    Text("Save review + scores")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.bingeLike.opacity(0.85))
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    busy
                        || reviewText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Error banner

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.12))
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    // MARK: - Load + state transitions

    private func load() async {
        guard loaded == nil, phase == .loading else { return }
        // Seed tone from last-used voice preference.
        if let saved = VoiceMode(rawValue: voiceRaw) { tone = saved }
        let api = ScribeAPI(baseURL: baseURL, apiKey: apiKey)
        async let configTask = api.getScribeConfig()
        let subj: LoadedSubject?
        do {
            subj = try await ScribeSubjectLoader.load(
                ref: subjectRef, baseURL: baseURL, apiKey: apiKey
            )
        } catch {
            // Real load error (schema mismatch, network, etc.).
            // Show the underlying message instead of the generic
            // "not found" — the generic message is reserved for
            // the case where the GraphQL succeeds with a null
            // payload (truly missing entity).
            errorText = friendlyError(error)
            phase = .error
            return
        }
        let cfg = await configTask
        guard let subj else {
            errorText = subjectRef.kind == "performer"
                ? "Performer not found"
                : "Scene not found"
            phase = .error
            return
        }
        loaded = LoadedState(subject: subj, config: cfg)
        // Honor the plugin's defaultTone only if the user hasn't
        // already locked in a preference via voiceRaw.
        if VoiceMode(rawValue: voiceRaw) == nil {
            tone = cfg.defaultTone
        }

        let saved = ScribeSessionStore.load(subj.sessionKey)
        let hasResumableInterview = (saved?.messages.count ?? 0) >= 2

        if hasResumableInterview, let saved {
            messages = saved.messages
            if let gen = saved.generated {
                reviewText = gen.review
                scores = gen.scores
                phase = .result
            } else {
                phase = .interview
            }
        } else if let existing = subj.existingReview, !existing.isEmpty {
            editMode = true
            reviewText = existing
            scores = subj.initialScores
            phase = .result
        } else {
            phase = .intro
        }
    }

    private func startManual() {
        guard let loaded else { return }
        _ = loaded
        editMode = true
        reviewText = ""
        scores = [:]
        phase = .result
    }

    private func startLLMInterview() {
        guard let loaded else { return }
        let sys = buildFreshSystem(loaded, tone: tone)
        messages = [sys]
        phase = .interview
        Task { await runKickoff(sys) }
    }

    /// First LLM call to seed the interview. Web's runKickoff
    /// (ScribeModal.tsx:L170). Sends the system message + a
    /// generic "Begin the interview" user line; the LLM's reply
    /// becomes the first visible assistant bubble.
    private func runKickoff(_ sys: LLMMessage) async {
        guard let loaded else { return }
        busy = true
        busyMsg = "Starting interview…"
        errorText = nil
        defer {
            busy = false
            busyMsg = ""
        }
        let api = ScribeAPI(baseURL: baseURL, apiKey: apiKey)
        do {
            let reply = try await api.callLLM(
                messages: [
                    sys,
                    LLMMessage(
                        role: .user,
                        content:
                            "Begin the interview with your first question."
                    ),
                ],
                config: loaded.config
            )
            let updated: [LLMMessage] = [
                sys,
                LLMMessage(role: .assistant, content: reply),
            ]
            messages = updated
            transcriptTick &+= 1
            ScribeSessionStore.save(
                loaded.subject.sessionKey,
                state: ScribeSessionState(
                    messages: updated, generated: nil
                )
            )
        } catch {
            errorText = friendlyError(error)
        }
    }

    private func sendMessage() async {
        guard let loaded, !busy else { return }
        let text = userInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if text.isEmpty { return }
        var next = messages
        next.append(LLMMessage(role: .user, content: text))
        messages = next
        userInput = ""
        transcriptTick &+= 1
        ScribeSessionStore.save(
            loaded.subject.sessionKey,
            state: ScribeSessionState(messages: next, generated: nil)
        )
        busy = true
        busyMsg = "Talking to the LLM…"
        errorText = nil
        defer {
            busy = false
            busyMsg = ""
        }
        let api = ScribeAPI(baseURL: baseURL, apiKey: apiKey)
        do {
            let reply = try await api.callLLM(
                messages: next, config: loaded.config
            )
            var after = next
            after.append(LLMMessage(role: .assistant, content: reply))
            messages = after
            transcriptTick &+= 1
            ScribeSessionStore.save(
                loaded.subject.sessionKey,
                state: ScribeSessionState(
                    messages: after, generated: nil
                )
            )
        } catch {
            errorText = friendlyError(error)
        }
    }

    private func generate() async {
        guard let loaded, !busy, canGenerate else { return }
        busy = true
        busyMsg = "Writing the review…"
        errorText = nil
        defer {
            busy = false
            busyMsg = ""
        }
        let crits = loaded.subject.criteria
        let criteriaList: String
        if !crits.isEmpty {
            criteriaList =
                "Criteria to score (give an integer 0–5 for each):\n"
                + crits.map { "- \($0.name)" }.joined(separator: "\n")
        } else {
            criteriaList =
                "No rating criteria configured — output the "
                + "REVIEW section only and skip SCORES."
        }
        var genMessages = messages
        genMessages.append(
            LLMMessage(
                role: .system,
                content:
                    loaded.subject.reviewContract + "\n\n"
                    + criteriaList
            )
        )
        genMessages.append(
            LLMMessage(
                role: .user,
                content: "Generate the review now."
            )
        )
        let api = ScribeAPI(baseURL: baseURL, apiKey: apiKey)
        do {
            let reply = try await api.callLLM(
                messages: genMessages, config: loaded.config
            )
            let parsed = api.parseGenerated(body: reply, criteria: crits)
            reviewText = parsed.review
            scores = parsed.scores
            ScribeSessionStore.save(
                loaded.subject.sessionKey,
                state: ScribeSessionState(
                    messages: messages,
                    generated: .init(
                        review: parsed.review, scores: parsed.scores
                    )
                )
            )
            phase = .result
        } catch {
            errorText = friendlyError(error)
        }
    }

    private func backToInterviewConfirmed() {
        guard let loaded else { return }
        if editMode {
            ScribeSessionStore.clear(loaded.subject.sessionKey)
            editMode = false
            let sys = buildFreshSystem(loaded, tone: tone)
            messages = [sys]
            reviewText = ""
            scores = [:]
            phase = .interview
            Task { await runKickoff(sys) }
            return
        }
        phase = .interview
        ScribeSessionStore.save(
            loaded.subject.sessionKey,
            state: ScribeSessionState(messages: messages, generated: nil)
        )
    }

    private func startOver() {
        guard let loaded else { return }
        ScribeSessionStore.clear(loaded.subject.sessionKey)
        editMode = false
        reviewText = ""
        scores = [:]
        messages = []
        phase = .intro
        errorText = nil
    }

    private func save(withScores: Bool) async {
        guard let loaded, !busy else { return }
        busy = true
        busyMsg = "Saving…"
        errorText = nil
        do {
            try await loaded.subject.save(
                .init(
                    reviewText: reviewText,
                    scoresByCriterion: withScores ? scores : [:],
                    autoCreate: loaded.config.autoCreateTags
                )
            )
            ScribeSessionStore.clear(loaded.subject.sessionKey)
            busyMsg = "Saved."
            // Brief pause so the "Saved" state is visible before
            // the sheet dismisses.
            try? await Task.sleep(for: .milliseconds(500))
            dismiss()
        } catch {
            errorText = friendlyError(error)
            busy = false
            busyMsg = ""
        }
    }

    // MARK: - System prompt assembly

    /// Build the system message that opens every interview.
    /// Mirrors web's ScribeModal.tsx buildFreshSystem (L35).
    private func buildFreshSystem(
        _ loaded: LoadedState, tone: VoiceMode
    ) -> LLMMessage {
        let voice = loaded.config.voicePrompts[tone]
            ?? SCRIBE_DEFAULT_VOICES[tone]
            ?? ""
        let criteria = loaded.subject.criteria
        let criteriaBlock: String
        if !criteria.isEmpty {
            criteriaBlock =
                "Rating criteria (referenced during interview, "
                + "scored at end):\n"
                + criteria.map { "- \($0.name)" }
                    .joined(separator: "\n")
                + "\n\n"
        } else {
            criteriaBlock = ""
        }
        let contextLabel =
            loaded.subject.ref.kind == "performer"
            ? "Performer" : "Scene"
        let voiceReminder =
            "REMINDER: Stay strictly in the voice set above "
            + "(\(tone.label) mode).\n\n"
        let content =
            "\(voice)\n\n"
            + "\(contextLabel) context:\n"
            + "\(loaded.subject.contextForLLM)\n\n"
            + criteriaBlock
            + "\(loaded.subject.interviewContract)\n\n"
            + voiceReminder
        return LLMMessage(role: .system, content: content)
    }
}

// MARK: - Helpers

/// Surface a clearer hint for the most common failure mode
/// (Ollama not running). Mirrors web's friendlyError.
private func friendlyError(_ e: Error) -> String {
    let msg = (e as? LocalizedError)?.errorDescription
        ?? "\(e)"
    let lower = msg.lowercased()
    if lower.contains("connection refused")
        || lower.contains("econnrefused")
        || lower.contains("failed to fetch")
        || lower.contains("failed to connect")
        || lower.contains("connection error")
    {
        return
            "Couldn't reach Ollama. Start it on the host "
            + "machine to generate new reviews — existing "
            + "reviews can still be edited and saved without it."
    }
    return msg
}
