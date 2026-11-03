import SwiftUI

/// AI command generator turns a natural-language task into one server shell command,
/// then lets the user review/insert/run; AI does not execute directly. Share chat's provider/location settings.
struct AICommandResult: Equatable {
    enum Risk: String { case safe, caution, danger }
    var command: String
    var explanation: String
    var risk: Risk

    /// Parse COMMAND/EXPLAIN/RISK lines, falling back to the first code line if malformed.
    static func parse(_ text: String) -> AICommandResult? {
        var command = "", explain = "", risk = Risk.caution
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("COMMAND:") { command = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if line.uppercased().hasPrefix("EXPLAIN:") { explain = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if line.uppercased().hasPrefix("RISK:") { risk = Risk(rawValue: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased()) ?? .caution }
        }
        if command.isEmpty {
            // Fallback: fenced code or first line.
            let stripped = text.replacingOccurrences(of: "```bash", with: "").replacingOccurrences(of: "```sh", with: "").replacingOccurrences(of: "```", with: "")
            command = stripped.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        command = command.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard !command.isEmpty else { return nil }
        return AICommandResult(command: command, explanation: explain, risk: risk)
    }
}

struct AICommandPopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var chat = AIChatModel.shared
    let host: Host
    let tabId: Int
    let directory: String?
    let onAgent: () -> Void
    let onClose: () -> Void

    @State private var request = ""
    @State private var generating = false
    @State private var result: AICommandResult?
    @State private var command = ""          // User-editable command.
    @State private var error: String?
    @State private var confirmDanger = false
    @FocusState private var focused: Bool

    private var riskColor: Color {
        switch result?.risk ?? .safe { case .safe: return Pal.green; case .caution: return Pal.yellow; case .danger: return Pal.red }
    }
    private var riskText: String {
        switch result?.risk ?? .safe {
        case .safe: return String(localized: "Looks safe (read-only)")
        case .caution: return String(localized: "Changes something — review first")
        case .danger: return String(localized: "Risky — could delete or overwrite data")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(lucideSymbol: "sparkles").foregroundStyle(Pal.tint)
                Text("AI Command").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Text(verbatim: host.name + (directory.map { " · " + $0 } ?? "")).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Pal.overlay).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .trailing)
            }
            engineRow
            TextField(String(localized: "Describe what you want to do, e.g. find files over 1 GB"), text: $request, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1...4)
                .focused($focused).onSubmit(generate)
                .padding(10).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("The AI only writes the command — nothing runs until you choose.").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer()
                Button(action: generate) {
                    HStack(spacing: 6) { if generating { ProgressView().controlSize(.small) }; Text(result == nil ? "Generate" : "Regenerate") }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(Pal.tint, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).pointerCursor().disabled(generating || request.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(request.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            if let error { Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(Pal.red).textSelection(.enabled) }
            if let r = result { resultCard(r) }
            Divider().overlay(Pal.fill(0.08))
            Button(action: onAgent) {
                Label(String(localized: "Let an AI agent on the server do the whole task…"), lucideSymbol: "terminal").font(.system(size: 11.5))
            }.buttonStyle(.plain).foregroundStyle(Pal.subtext).pointerCursor()
        }
        .padding(16).frame(width: 440).background(Pal.solidBase)
        .onAppear { focused = true }
    }

    /// Select registered AI profiles shared with chat, with immediate edit/add access.
    private var engineRow: some View {
        let session = chat.session(for: host.id)
        let current = chat.profile(id: session.profileId)
        return HStack(spacing: 8) {
            Menu {
                ForEach(chat.profiles) { p in
                    Button { chat.selectProfile(p.id, hostId: host.id) } label: {
                        let text = "\(p.displayName) · \(p.provider.shortName)"
                        if p.id == session.profileId { Label(text, lucideSymbol: "checkmark") } else { Text(verbatim: text) }
                    }
                }
                if !chat.profiles.isEmpty { Divider() }
                if let current {
                    Button { edit(ProfileEditTarget(profile: current, isNew: false)) } label: { Label(String(localized: "Edit This AI…"), lucideSymbol: "pencil") }
                }
                Button { edit(ProfileEditTarget(profile: AIProfile(name: "", provider: chat.defaultProvider), isNew: true)) } label: {
                    Label(String(localized: "Add AI…"), lucideSymbol: "plus")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(lucideSymbol: current?.provider.icon ?? "sparkle").foregroundStyle(Pal.tint)
                    Text(verbatim: current?.displayName ?? String(localized: "Add AI…")).fontWeight(.semibold).foregroundStyle(Pal.text)
                    if AppEnv.localTerminalEnabled, let current {
                        Text(verbatim: current.location == .local ? String(localized: "My Mac") : String(localized: "Server"))
                            .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Pal.fill(0.08), in: Capsule())
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help(String(localized: "Choose which AI to use"))
            Spacer()
            let m = chat.effectiveModel(hostId: host.id)
            Text(verbatim: m.isEmpty ? String(localized: "CLI default model") : m).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.overlay).lineLimit(1)
        }
    }

    private func edit(_ target: ProfileEditTarget) {
        onClose()
        DispatchQueue.main.async { model.aiProfileEdit = ProfileEditRequest(hostId: host.id, target: target) }
    }

    private func resultCard(_ r: AICommandResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $command, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Pal.text).lineLimit(1...6)
                .padding(10).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(riskColor.opacity(0.5), lineWidth: 1))
            if !r.explanation.isEmpty { Text(verbatim: r.explanation).font(.system(size: 12)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 6) { Circle().fill(riskColor).frame(width: 7, height: 7); Text(verbatim: riskText).font(.system(size: 11)).foregroundStyle(riskColor) }
            HStack(spacing: 8) {
                Button { insert(run: false) } label: { action("Insert", filled: true) }.buttonStyle(.plain).pointerCursor()
                Button {
                    if r.risk == .danger && !confirmDanger { confirmDanger = true } else { insert(run: true) }
                } label: { action(confirmDanger ? "Run anyway" : "Run", filled: false, tint: r.risk == .danger ? Pal.red : nil) }
                    .buttonStyle(.plain).pointerCursor()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                } label: { action("Copy", filled: false) }.buttonStyle(.plain).pointerCursor()
                Spacer()
            }
        }
    }

    private func action(_ title: LocalizedStringKey, filled: Bool, tint: Color? = nil) -> some View {
        Text(title).font(.system(size: 12, weight: .medium))
            .foregroundStyle(filled ? Color.white : (tint ?? Pal.text))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(filled ? Pal.tint : Pal.fill(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private func insert(run: Bool) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        model.sendTerminalText(tabId, run ? c + "\n" : c)
        onClose()
    }

    private func generate() {
        let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, !generating else { return }
        guard let conn = host.ssh else { error = String(localized: "This host has no SSH connection."); return }
        generating = true; error = nil; confirmDanger = false
        let session = chat.session(for: host.id)
        let provider = session.provider, location = session.location
        let modelName = chat.effectiveModel(hostId: host.id)
        let lang = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("ko") ? "Korean" : "English"
        let os = host.isLocal ? "macOS" : (host.os.isEmpty ? "Linux" : host.os)
        let extraPrompt = chat.profile(id: session.profileId)?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extra = extraPrompt.isEmpty ? "" : "\n\nAdditional instructions from the user (follow them, but keep the three-line reply format):\n" + extraPrompt
        let system = """
        You write shell commands. Target: \(os) server "\(host.name)", shell sh/bash, current directory \(directory ?? "unknown").
        Reply with EXACTLY three lines and nothing else:
        COMMAND: <one shell command or pipeline on a single line, no backticks, no placeholders unless unavoidable>
        EXPLAIN: <one sentence in \(lang) saying what it does>
        RISK: <safe | caution | danger>
        Use safe for read-only commands, caution for commands that change files/services/config, danger for anything that deletes or overwrites data, formats disks, or could lock the user out.
        Prefer the simplest portable command. Do not run anything yourself.
        """ + extra
        Task { @MainActor in
            do {
                let reply = try await AIChatClient.send(connection: conn, provider: provider, location: location,
                                                        messages: [AIChatMessage(role: .user, content: ask)],
                                                        model: modelName, systemPrompt: system, directory: directory)
                if let r = AICommandResult.parse(reply) { result = r; command = r.command }
                else { error = String(localized: "The AI didn't return a command. Try rephrasing.") }
            } catch { self.error = error.localizedDescription }
            generating = false
        }
    }
}

/// App-level profile-sheet request, since sheets are awkward to present from popovers.
struct ProfileEditRequest: Identifiable {
    let id = UUID()
    let hostId: String
    let target: ProfileEditTarget
}
