import Foundation

/// Remote SSH CLI provider used by AI chat.
enum AIAPIProvider: String, CaseIterable, Codable, Identifiable {
    case openai, anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "ChatGPT (Codex CLI)"
        case .anthropic: return "Claude CLI"
        }
    }

    /// Short user-facing name without developer terminology.
    var shortName: String { self == .openai ? "ChatGPT" : "Claude" }

    var icon: String {
        switch self {
        case .openai: return "circle.grid.2x2.fill"
        case .anthropic: return "sparkle"
        }
    }

}

/// Common models plus manual entry; CLI accepts aliases (opus/sonnet/haiku) and full IDs.
enum AIModelPresets {
    static func list(for provider: AIAPIProvider) -> [(id: String, title: String)] {
        switch provider {
        case .anthropic:
            return [("sonnet", "Sonnet (latest)"), ("opus", "Opus (latest)"), ("haiku", "Haiku (latest)"),
                    ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-opus-5-5", "Opus 5.5"), ("claude-haiku-4-5-20251001", "Haiku 4.5")]
        case .openai:
            return []   // Fetch Codex model/list at the selected execution location.
        }
    }
}

/// Pass returned Codex model IDs unchanged to execution.
struct AIModelOption: Decodable, Identifiable {
    let model: String
    let displayName: String
    let hidden: Bool
    var id: String { model }

    private enum CodingKeys: String, CodingKey { case model, id, displayName, hidden }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? values.decode(String.self, forKey: .id)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? model
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

enum AIChatExecutionLocation: String, Codable, CaseIterable, Identifiable {
    case local, remote

    var id: String { rawValue }
    /// Default to running on this Mac; MAS sandbox runs on the server instead.
    static var defaultValue: AIChatExecutionLocation { AppEnv.localTerminalEnabled ? .local : .remote }
    var displayName: String {
        switch self {
        case .local: return String(localized: "Run on my Mac")
        case .remote: return String(localized: "Run on the server")
        }
    }
}

enum AIChatRole: String, Codable {
    case user, assistant
}

struct AIChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: AIChatRole
    var content: String
    let createdAt: Date
    var isError: Bool = false

    init(id: UUID = UUID(), role: AIChatRole, content: String, createdAt: Date = Date(), isError: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isError = isError
    }
}

/// Global reusable AI profile: provider, execution location, and default conversation instructions.
struct AIProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var provider: AIAPIProvider = .anthropic
    var location: AIChatExecutionLocation = AIChatExecutionLocation.defaultValue
    /// Default prompt sent with every question, e.g. "Reply in Korean; ask before deleting files."
    var prompt: String = ""
    /// Profile model; nil/empty uses provider settings, then CLI default.
    var model: String? = nil

    var displayName: String { name.isEmpty ? provider.shortName : name }
}

/// One conversation; retain multiple per host for later continuation.
struct AIChatConversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String = ""
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [AIChatMessage] = []

    /// Fallback title before the first question.
    var displayTitle: String { title.isEmpty ? String(localized: "New Conversation") : title }
}

/// Per-host history stored by hostId in [[AIChatStore]].
struct AIChatSessionData: Codable {
    var provider: AIAPIProvider = .anthropic
    var location: AIChatExecutionLocation = AIChatExecutionLocation.defaultValue
    var conversations: [AIChatConversation] = []
    var activeId: UUID?
    var profileId: UUID?   // Selected AI profile for this host.
    var workDir: String?   // Explicit server working folder, or terminal cwd when nil.

    init(provider: AIAPIProvider = .anthropic, location: AIChatExecutionLocation = AIChatExecutionLocation.defaultValue,
         conversations: [AIChatConversation] = [], activeId: UUID? = nil, profileId: UUID? = nil, workDir: String? = nil) {
        self.provider = provider
        self.location = location
        self.conversations = conversations
        self.activeId = activeId
        self.profileId = profileId
        self.workDir = workDir
    }

    private enum CodingKeys: String, CodingKey { case provider, location, messages, conversations, activeId, profileId, workDir }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(AIAPIProvider.self, forKey: .provider) ?? .anthropic
        location = try values.decodeIfPresent(AIChatExecutionLocation.self, forKey: .location) ?? AIChatExecutionLocation.defaultValue
        conversations = try values.decodeIfPresent([AIChatConversation].self, forKey: .conversations) ?? []
        activeId = try values.decodeIfPresent(UUID.self, forKey: .activeId)
        profileId = try values.decodeIfPresent(UUID.self, forKey: .profileId)
        workDir = try values.decodeIfPresent(String.self, forKey: .workDir)
        // Migrate older single-conversation messages into one history entry.
        if conversations.isEmpty,
           let legacy = try values.decodeIfPresent([AIChatMessage].self, forKey: .messages), !legacy.isEmpty {
            let title = AIChatConversation.makeTitle(from: legacy.first(where: { $0.role == .user })?.content ?? "")
            let conv = AIChatConversation(title: title, createdAt: legacy.first?.createdAt ?? Date(),
                                          updatedAt: legacy.last?.createdAt ?? Date(), messages: legacy)
            conversations = [conv]
            activeId = conv.id
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(location, forKey: .location)
        try c.encode(conversations, forKey: .conversations)
        try c.encodeIfPresent(activeId, forKey: .activeId)
        try c.encodeIfPresent(profileId, forKey: .profileId)
        try c.encodeIfPresent(workDir, forKey: .workDir)
    }
}

extension AIChatConversation {
    /// Derive the title from the first user's first line.
    static func makeTitle(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }
}
