import Foundation

/// Per-host conversation state observed by its chat panel, avoiding updates from unrelated hosts,
/// following TabsModel/LayoutModel's separation from AppModel.
@MainActor
final class AIChatSessionState: ObservableObject {
    let hostId: String
    @Published var provider: AIAPIProvider
    @Published var location: AIChatExecutionLocation
    /// Active conversation messages; the panel observes only these.
    @Published var messages: [AIChatMessage]
    /// All host conversations; snapshot synchronizes the active messages.
    @Published var conversations: [AIChatConversation]
    @Published var activeId: UUID
    @Published var isSending = false
    /// Selected AI profile supplies provider/location/default prompt.
    @Published var profileId: UUID?
    /// Explicit working folder; nil follows terminal cwd.
    @Published var workDir: String?
    /// Server paths to attach to the next message; clear after sending.
    @Published var attachments: [String] = []
    /// Keep draft input in session state so tab/view reconstruction preserves it.
    @Published var draft = ""

    init(hostId: String, data: AIChatSessionData) {
        self.hostId = hostId
        self.provider = data.provider
        self.location = data.location
        self.profileId = data.profileId
        self.workDir = data.workDir
        var convs = data.conversations
        let active: AIChatConversation
        if let id = data.activeId, let found = convs.first(where: { $0.id == id }) {
            active = found
        } else if let last = convs.max(by: { $0.updatedAt < $1.updatedAt }) {
            active = last
        } else {
            active = AIChatConversation()
            convs = [active]
        }
        self.conversations = convs
        self.activeId = active.id
        self.messages = active.messages
    }

    /// Synchronize active messages into conversations.
    func syncActive() {
        guard let i = conversations.firstIndex(where: { $0.id == activeId }) else { return }
        conversations[i].messages = messages
        if let last = messages.last { conversations[i].updatedAt = last.createdAt }
        if conversations[i].title.isEmpty,
           let firstUser = messages.first(where: { $0.role == .user }) {
            conversations[i].title = AIChatConversation.makeTitle(from: firstUser.content)
        }
    }

    func snapshot() -> AIChatSessionData {
        syncActive()
        // Do not persist empty inactive conversations.
        let kept = conversations.filter { $0.id == activeId || !$0.messages.isEmpty }
        return AIChatSessionData(provider: provider, location: location, conversations: kept, activeId: activeId, profileId: profileId, workDir: workDir)
    }
}

/// Manage CLI model preferences and per-host AI conversations.
/// Follow the app-wide singleton pattern of [[AppSettings]]/[[ThemeManager]].
@MainActor
final class AIChatModel: ObservableObject {
    static let shared = AIChatModel()

    @Published var defaultProvider: AIAPIProvider {
        didSet { UserDefaults.standard.set(defaultProvider.rawValue, forKey: "aiChatDefaultProvider") }
    }
    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "aiChatOpenAIModel") }
    }
    @Published var anthropicModel: String {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: "aiChatAnthropicModel") }
    }

    /// Global registered AI profiles.
    @Published private(set) var profiles: [AIProfile] = AIChatStore.loadProfiles()
    private var lastProfileId: UUID? {
        get { UserDefaults.standard.string(forKey: "aiChatLastProfile").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "aiChatLastProfile") }
    }

    private var sessions: [String: AIChatSessionState] = [:]
    private var sessionData: [String: AIChatSessionData]

    private init() {
        sessionData = AIChatStore.loadAll()
        let d = UserDefaults.standard
        defaultProvider = AIAPIProvider(rawValue: d.string(forKey: "aiChatDefaultProvider") ?? "") ?? .anthropic
        openAIModel = d.string(forKey: "aiChatOpenAIModel") ?? ""
        anthropicModel = d.string(forKey: "aiChatAnthropicModel") ?? ""
    }

    /// Empty model lets the CLI select its default.
    func model(for provider: AIAPIProvider) -> String {
        let raw: String
        switch provider {
        case .openai: raw = openAIModel
        case .anthropic: raw = anthropicModel
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed
    }

    /// Effective model priority: profile, provider preference, then CLI default.
    func effectiveModel(hostId: String) -> String {
        let s = session(for: hostId)
        if let m = profile(id: s.profileId)?.model?.trimmingCharacters(in: .whitespaces), !m.isEmpty { return m }
        return model(for: s.provider)
    }

    /// Get the host session, restoring history or creating one if absent.
    func session(for hostId: String) -> AIChatSessionState {
        if let s = sessions[hostId] { return s }
        var data = sessionData[hostId] ?? AIChatSessionData()
        if sessionData[hostId] == nil { data.provider = defaultProvider }
        if !AppEnv.localTerminalEnabled { data.location = .remote }
        let s = AIChatSessionState(hostId: hostId, data: data)
        sessions[hostId] = s
        resolveProfile(s)
        return s
    }

    // MARK: AI profiles

    func profile(id: UUID?) -> AIProfile? { id.flatMap { id in profiles.first { $0.id == id } } }

    /// Choose last-used/first profile if current is invalid; retain nil when none exist.
    private func resolveProfile(_ s: AIChatSessionState) {
        if let p = profile(id: s.profileId) { apply(p, to: s); return }
        s.profileId = nil
        if let p = profile(id: lastProfileId) ?? profiles.first { s.profileId = p.id; apply(p, to: s) }
    }

    private func apply(_ p: AIProfile, to s: AIChatSessionState) {
        s.provider = p.provider
        s.location = AppEnv.localTerminalEnabled ? p.location : .remote
    }

    func addProfile(_ p: AIProfile, selectFor hostId: String? = nil) {
        profiles.append(p)
        AIChatStore.saveProfiles(profiles)
        lastProfileId = p.id
        for s in sessions.values where s.profileId == nil { resolveProfile(s) }
        if let hostId { selectProfile(p.id, hostId: hostId) }
    }

    func updateProfile(_ p: AIProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
        AIChatStore.saveProfiles(profiles)
        for s in sessions.values where s.profileId == p.id { apply(p, to: s); persist(s.hostId) }
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        AIChatStore.saveProfiles(profiles)
        if lastProfileId == id { lastProfileId = nil }
        for s in sessions.values where s.profileId == id { s.profileId = nil; resolveProfile(s); persist(s.hostId) }
    }

    /// Set working folder; nil resumes following terminal cwd.
    func setWorkDir(_ path: String?, hostId: String) {
        let s = session(for: hostId)
        s.workDir = path
        persist(hostId)
    }

    func selectProfile(_ id: UUID, hostId: String) {
        let s = session(for: hostId)
        guard !s.isSending, let p = profile(id: id) else { return }
        s.profileId = id
        apply(p, to: s)
        lastProfileId = id
        persist(hostId)
    }

    /// Send a user message and receive the remote CLI response.
    func send(hostId: String, hostName: String, connection: SSHConnection?, directory: String?, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = session(for: hostId)
        guard !trimmed.isEmpty, !session.isSending else { return }

        session.messages.append(AIChatMessage(role: .user, content: trimmed))
        session.isSending = true
        persist(hostId)   // Persist the question immediately in case the app exits while waiting.
        let provider = session.provider
        let location = session.location
        let model = effectiveModel(hostId: hostId)
        let history = session.messages
        var system = Self.systemPrompt(hostName: hostName, directory: directory)
        if let extra = profile(id: session.profileId)?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            system += "\n\nAdditional instructions from the user (follow them):\n" + extra
        }

        Task { @MainActor in
            do {
                guard let connection else { throw AIChatClientError(message: "This host has no SSH connection.") }
                let reply = try await AIChatClient.send(connection: connection, provider: provider, location: location, messages: history, model: model, systemPrompt: system, directory: directory)
                session.messages.append(AIChatMessage(role: .assistant, content: reply))
            } catch {
                session.messages.append(AIChatMessage(role: .assistant, content: error.localizedDescription, isError: true))
            }
            session.isSending = false
            self.persist(hostId)
        }
    }

    /// Resend the last user message after removing subsequent responses/errors.
    func retryLast(hostId: String, hostName: String, connection: SSHConnection?, directory: String?) {
        guard let session = sessions[hostId], !session.isSending else { return }
        while let last = session.messages.last, last.role == .assistant { session.messages.removeLast() }
        guard let lastUser = session.messages.last, lastUser.role == .user else { return }
        session.messages.removeLast()   // send() appends this message again.
        send(hostId: hostId, hostName: hostName, connection: connection, directory: directory, prompt: lastUser.content)
    }

    /// Start another conversation, retaining history for later reopening.
    /// Reuse the current conversation if empty.
    func newConversation(hostId: String) {
        guard let session = sessions[hostId], !session.isSending else { return }
        guard !session.messages.isEmpty else { return }
        session.syncActive()
        let conv = AIChatConversation()
        session.conversations.append(conv)
        session.activeId = conv.id
        session.messages = []
        persist(hostId)
    }

    /// Reopen and continue a previous conversation.
    func selectConversation(hostId: String, id: UUID) {
        guard let session = sessions[hostId], !session.isSending, id != session.activeId,
              let target = session.conversations.first(where: { $0.id == id }) else { return }
        session.syncActive()
        // Remove an empty conversation when leaving it.
        session.conversations.removeAll { $0.id == session.activeId && $0.messages.isEmpty }
        session.activeId = target.id
        session.messages = target.messages
        persist(hostId)
    }

    /// Delete one conversation; deleting active selects the latest remaining or creates one.
    func deleteConversation(hostId: String, id: UUID) {
        guard let session = sessions[hostId], !session.isSending else { return }
        session.syncActive()
        session.conversations.removeAll { $0.id == id }
        if id == session.activeId {
            if let next = session.conversations.max(by: { $0.updatedAt < $1.updatedAt }) {
                session.activeId = next.id
                session.messages = next.messages
            } else {
                let conv = AIChatConversation()
                session.conversations = [conv]
                session.activeId = conv.id
                session.messages = []
            }
        }
        persist(hostId)
    }

    /// Change this host's provider, shared by chat and command generation.
    func setProvider(_ provider: AIAPIProvider, hostId: String) {
        let session = session(for: hostId)
        guard !session.isSending, session.provider != provider else { return }
        session.provider = provider
        persist(hostId)
    }

    func setLocation(_ location: AIChatExecutionLocation, hostId: String) {
        let session = session(for: hostId)
        guard !session.isSending else { return }
        session.location = location
        persist(hostId)
    }

    private func persist(_ hostId: String) {
        guard let s = sessions[hostId] else { return }
        sessionData[hostId] = s.snapshot()
        AIChatStore.saveAll(sessionData)
    }

    private static func systemPrompt(hostName: String, directory: String?) -> String {
        var s = "You are an AI assistant embedded in ServerDock, a macOS SSH client, helping the user manage the server \"\(hostName)\"."
        if let directory, !directory.isEmpty {
            s += " The user's terminal on this server is currently in the directory: \(directory)."
        }
        s += " Lines in the user's message that start with \"📎\" are paths on the server the user is pointing at (files or folders)."
        s += " When you suggest a shell command, put it in a fenced code block so the user can run it from the chat panel."
        return s
    }
}
