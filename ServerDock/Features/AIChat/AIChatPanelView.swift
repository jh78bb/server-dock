import AppKit
import SwiftUI

/// Split plain text/code fences; code blocks offer Send to Terminal.
private struct ChatSegment: Identifiable {
    enum Kind { case text, code(language: String?) }
    let id = UUID()
    let kind: Kind
    let content: String
}

private func parseSegments(_ text: String) -> [ChatSegment] {
    var segments: [ChatSegment] = []
    let lines = text.components(separatedBy: "\n")
    var buffer: [String] = []
    func flushText() {
        let joined = buffer.joined(separator: "\n")
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(ChatSegment(kind: .text, content: joined))
        }
        buffer = []
    }
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if line.hasPrefix("```") {
            flushText()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            i += 1
            while i < lines.count, !lines[i].hasPrefix("```") {
                code.append(lines[i])
                i += 1
            }
            segments.append(ChatSegment(kind: .code(language: lang.isEmpty ? nil : lang), content: code.joined(separator: "\n")))
            i += 1   // Skip the closing code fence.
            continue
        }
        buffer.append(line)
        i += 1
    }
    flushText()
    return segments
}

/// Per-host chat panel: provider, history, and composer; New Conversation resets active history.
struct AIChatPanelView: View {
    let model: AppModel
    let host: Host
    @ObservedObject private var chat = AIChatModel.shared
    @ObservedObject private var session: AIChatSessionState
    @State private var editTarget: ProfileEditTarget?
    @State private var showPathPicker = false
    @FocusState private var inputFocused: Bool

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        self._session = ObservedObject(wrappedValue: AIChatModel.shared.session(for: host.id))
    }

    /// Use the explicit AI folder, falling back to terminal cwd.
    private var currentDirectory: String? { session.workDir ?? terminalDirectory }

    private var terminalDirectory: String? {
        guard let tab = model.tabs.first(where: { $0.kind == .terminal && $0.hostId == host.id }) else { return nil }
        return model.terminalConn(for: tab.id)?.cwd
    }

    var body: some View {
        Group {
            if chat.profiles.isEmpty {
                noProfileState          // Without profiles, guide the user to Add AI.
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Pal.fill(0.06))
                    messageList
                    Divider().overlay(Pal.fill(0.06))
                    inputArea
                }
            }
        }
        .background(Pal.base)
        .sheet(item: $editTarget) { target in
            AIProfileEditor(
                profile: target.profile, isNew: target.isNew, connection: model.host(host.id)?.ssh ?? host.ssh,
                onSave: { p in
                    if target.isNew { chat.addProfile(p, selectFor: host.id) } else { chat.updateProfile(p) }
                    editTarget = nil
                },
                onDelete: { chat.deleteProfile(id: target.profile.id); editTarget = nil },
                onCancel: { editTarget = nil })
        }
    }

    private func newProfileTarget() -> ProfileEditTarget {
        ProfileEditTarget(profile: AIProfile(name: "", provider: chat.defaultProvider), isNew: true)
    }

    /// Empty state when no AI profiles exist.
    private var noProfileState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(lucideSymbol: "sparkles").font(.system(size: 28)).foregroundStyle(Pal.tint)
            Text("Add an AI to get started").font(.system(size: 15, weight: .bold)).foregroundStyle(Pal.text)
            Text("Register the AI you want to use (Claude or ChatGPT), where it should run, and your standing instructions. You can add several and switch between them here.")
                .font(.system(size: 12.5)).foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            PrimaryButton(title: "Add AI") { editTarget = newProfileTarget() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        // Single-row blocks: AI selector, server folder, history, New Conversation.
        HStack(spacing: 8) {
            profileMenu

            pathButton

            Spacer(minLength: 4)
            historyMenu
            Button {
                chat.newConversation(hostId: host.id)
            } label: {
                Image(lucideSymbol: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().help(String(localized: "New Conversation"))
            .disabled(session.isSending)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Working-folder button opens a server file/folder picker for AI context.
    private var pathButton: some View {
        let custom = session.workDir != nil
        return Button { showPathPicker.toggle() } label: {
            HStack(spacing: 5) {
                Image(lucideSymbol: "folder").font(.system(size: 10))
                Text(verbatim: currentDirectory ?? String(localized: "Choose folder…"))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                Image(lucideSymbol: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(custom ? Pal.tint : Pal.subtext)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((custom ? Pal.tint.opacity(0.12) : Pal.fill(0.05)), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .layoutPriority(-1)
        .help(String(localized: "Choose the server folder or files for the AI to work with"))
        .popover(isPresented: $showPathPicker, arrowEdge: .bottom) {
            AIPathPicker(
                fs: RemoteFS(host.ssh ?? SSHConnection()),
                startPath: currentDirectory,
                workDir: session.workDir,
                attachments: session.attachments,
                onUseFolder: { path in chat.setWorkDir(path, hostId: host.id); showPathPicker = false },
                onFollowTerminal: { chat.setWorkDir(nil, hostId: host.id); showPathPicker = false },
                onToggleAttach: { path in
                    if let i = session.attachments.firstIndex(of: path) { session.attachments.remove(at: i) }
                    else { session.attachments.append(path) }
                })
        }
    }

    /// Registered-profile menu with Edit Current/Add New actions.
    private var profileMenu: some View {
        let current = chat.profile(id: session.profileId)
        return Menu {
            ForEach(chat.profiles) { p in
                Button {
                    chat.selectProfile(p.id, hostId: host.id)
                } label: {
                    let text = "\(p.displayName) · \(p.provider.shortName)"
                    if p.id == session.profileId { Label(text, lucideSymbol: "checkmark") } else { Text(verbatim: text) }
                }
            }
            Divider()
            if let current {
                Button { editTarget = ProfileEditTarget(profile: current, isNew: false) } label: {
                    Label(String(localized: "Edit This AI…"), lucideSymbol: "pencil")
                }
            }
            Button { editTarget = newProfileTarget() } label: {
                Label(String(localized: "Add AI…"), lucideSymbol: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(lucideSymbol: current?.provider.icon ?? "sparkle").foregroundStyle(Pal.tint)
                Text(verbatim: current?.displayName ?? "—").fontWeight(.semibold).foregroundStyle(Pal.text)
                if AppEnv.localTerminalEnabled, let current {
                    Text(verbatim: current.location == .local ? String(localized: "My Mac") : String(localized: "Server"))
                        .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Pal.fill(0.08), in: Capsule())
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .fixedSize()
        .disabled(session.isSending)
        .help(String(localized: "Choose which AI to use"))
    }

    /// Select previous host conversations to continue; offer deleting the current one below.
    private var historyMenu: some View {
        let convs = session.conversations
            .filter { !$0.messages.isEmpty || $0.id == session.activeId }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Menu {
            ForEach(convs) { conv in
                Button {
                    chat.selectConversation(hostId: host.id, id: conv.id)
                } label: {
                    let label = "\(conv.displayTitle) · \(Self.dateFmt.string(from: conv.updatedAt))"
                    if conv.id == session.activeId {
                        Label(label, lucideSymbol: "checkmark")
                    } else {
                        Text(verbatim: label)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                chat.deleteConversation(hostId: host.id, id: session.activeId)
            } label: {
                Label(String(localized: "Delete This Conversation"), lucideSymbol: "trash")
            }
            .disabled(session.messages.isEmpty)
        } label: {
            Image(lucideSymbol: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Conversation History"))
        .disabled(session.isSending)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f
    }()

    @ViewBuilder
    private var messageList: some View {
        if session.messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // LazyVStack estimates unseen bubble heights and misplaces scrollTo after long replies; use VStack.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(session.messages.enumerated()), id: \.element.id) { idx, message in
                            MessageBubble(
                                message: message,
                                isLast: idx == session.messages.count - 1,
                                onSendToTerminal: { code in model.sendCommandToTerminal(hostId: host.id, command: code) },
                                onRetry: { chat.retryLast(hostId: host.id, hostName: host.name, connection: host.ssh, directory: currentDirectory) }
                            )
                            .id(message.id)
                        }
                        if session.isSending {
                            typingIndicator.id("__typing__")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: session.messages.count) { _ in scrollToEnd(proxy) }
                .onChange(of: session.isSending) { _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy, animated: false) }
            }
        }
    }

    /// After sending, scroll to pending input; on reply, align its start beneath the question.
    /// Previously aligning the reply's end pushed long questions offscreen and reversed the apparent reading order.
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            let animation: Animation? = animated ? .easeOut(duration: 0.2) : nil
            if session.isSending {
                withAnimation(animation) { proxy.scrollTo("__typing__", anchor: .bottom) }
            } else if let last = session.messages.last {
                // Show assistant response starts and user message ends.
                withAnimation(animation) { proxy.scrollTo(last.id, anchor: last.role == .assistant && animated ? .top : .bottom) }
            }
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.system(size: 12)).foregroundStyle(Pal.overlay)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(lucideSymbol: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(Pal.tint)
            Text("Ask about \(host.name)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Pal.text)
            Text("Chats with \(session.provider.displayName) about this server. Suggested commands can be sent straight to the terminal.")
                .font(.system(size: 12))
                .foregroundStyle(Pal.overlay)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text(session.location == .local
                 ? String(localized: "Runs the CLI on this Mac and connects to the server over SSH.")
                 : String(localized: "Requires the selected CLI installed and signed in on this server."))
                .font(.system(size: 11))
                .foregroundStyle(Pal.overlay)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.attachments, id: \.self) { path in
                            HStack(spacing: 4) {
                                Image(lucideSymbol: "paperclip").font(.system(size: 10))
                                Text(verbatim: (path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Button { session.attachments.removeAll { $0 == path } } label: {
                                    Image(lucideSymbol: "xmark.circle.fill").font(.system(size: 11))
                                }.buttonStyle(.plain)
                            }
                            .foregroundStyle(Pal.text)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Pal.tint.opacity(0.14), in: Capsule())
                            .help(path)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ThemedTextEditor(placeholder: "Message \(session.provider.displayName)…", text: $session.draft, onSubmit: sendDraft)
                    .frame(minHeight: 40, maxHeight: 120)
                Button(action: sendDraft) {
                    Image(lucideSymbol: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? Pal.tint : Pal.overlay.opacity(0.5))
                }
                .buttonStyle(.plain)
                .pointerCursor(canSend)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            Text("Enter to send · Shift+Enter for a new line").font(.system(size: 10)).foregroundStyle(Pal.overlay)
        }
        .padding(10)
    }

    private var canSend: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isSending
    }

    private func sendDraft() {
        guard canSend else { return }
        var prompt = session.draft
        // Append selected server paths as attachment lines, visible in the bubble too.
        if !session.attachments.isEmpty {
            prompt += "\n\n" + session.attachments.map { "📎 " + $0 }.joined(separator: "\n")
            session.attachments = []
        }
        session.draft = ""
        chat.send(hostId: host.id, hostName: host.name, connection: host.ssh, directory: currentDirectory, prompt: prompt)
    }
}

private struct MessageBubble: View {
    let message: AIChatMessage
    let isLast: Bool
    let onSendToTerminal: (String) -> Void
    let onRetry: () -> Void
    @State private var hover = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(parseSegments(message.content)) { segment in
                    switch segment.kind {
                    case .text:
                        Text(segment.content)
                            .font(.system(size: 13))
                            .foregroundStyle(message.isError ? Pal.red : Pal.text)
                            .textSelection(.enabled)
                    case .code(let language):
                        CodeBlockView(code: segment.content, language: language, onSendToTerminal: onSendToTerminal)
                    }
                }
                if message.isError && isLast {
                    Button(action: onRetry) {
                        Label("Retry", lucideSymbol: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .foregroundStyle(Pal.tint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if hover {
                    copyButton.padding(4)
                }
            }
            .onHover { hover = $0 }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        if message.isError { return Pal.red.opacity(0.10) }
        return isUser ? Pal.tint.opacity(0.14) : Pal.fill(0.05)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Image(lucideSymbol: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(Pal.overlay)
                .frame(width: 20, height: 20)
                .background(Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).pointerCursor().help(String(localized: "Copy"))
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    let onSendToTerminal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? String(localized: "CODE"))
                    .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Pal.overlay)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(lucideSymbol: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain).pointerCursor().foregroundStyle(Pal.overlay).help(String(localized: "Copy"))
                Button {
                    onSendToTerminal(code)
                } label: {
                    Label("Run in Terminal", lucideSymbol: "terminal")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain).pointerCursor().foregroundStyle(Pal.tint)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Pal.fill(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.08), lineWidth: 1))
    }
}


/// Profile-sheet target: new or existing profile.
struct ProfileEditTarget: Identifiable {
    let id = UUID()
    var profile: AIProfile
    var isNew: Bool
}

/// Profile form: name, provider, explained execution location, default prompt.
struct AIProfileEditor: View {
    @State var profile: AIProfile
    let isNew: Bool
    let connection: SSHConnection?
    let onSave: (AIProfile) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var confirmDelete = false
    @State private var customModel = false   // Manual entry after selecting Other Model.
    @State private var loadedModels: [AIModelOption] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var modelRevision = 0

    init(profile: AIProfile, isNew: Bool, connection: SSHConnection? = nil, onSave: @escaping (AIProfile) -> Void,
         onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self._profile = State(initialValue: profile)
        self.isNew = isNew; self.connection = connection
        self.onSave = onSave; self.onDelete = onDelete; self.onCancel = onCancel
    }

    /// Model selector: CLI default, common models, or custom entry.
    @ViewBuilder private var modelPicker: some View {
        let presets = profile.provider == .openai
            ? loadedModels.map { (id: $0.model, title: $0.displayName) }
            : AIModelPresets.list(for: profile.provider)
        let current = (profile.model ?? "").trimmingCharacters(in: .whitespaces)
        let isPreset = presets.contains { $0.id == current }
        let label = current.isEmpty ? String(localized: "Default (CLI decides)") : (presets.first { $0.id == current }?.title ?? current)
        HStack(spacing: 8) {
            Menu {
                Button { profile.model = nil; customModel = false } label: {
                    if current.isEmpty && !customModel { Label(String(localized: "Default (CLI decides)"), lucideSymbol: "checkmark") } else { Text("Default (CLI decides)") }
                }
                Divider()
                ForEach(presets, id: \.id) { m in
                    Button { profile.model = m.id; customModel = false } label: {
                        if m.id == current && !customModel { Label("\(m.title)  ·  \(m.id)", lucideSymbol: "checkmark") } else { Text(verbatim: "\(m.title)  ·  \(m.id)") }
                    }
                }
                Divider()
                Button { customModel = true } label: { Label(String(localized: "Other model…"), lucideSymbol: "pencil") }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: customModel ? String(localized: "Other model…") : label).font(.system(size: 12.5)).foregroundStyle(Pal.text)
                    Image(lucideSymbol: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Pal.subtext)
                }
                .padding(.horizontal, 10).padding(.vertical, 6).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            if profile.provider == .openai {
                Button { modelRevision += 1 } label: {
                    HStack(spacing: 5) {
                        if loadingModels { ProgressView().controlSize(.mini) }
                        else { Image(lucideSymbol: "arrow.clockwise") }
                        Text(loadingModels ? "Loading models…" : "Load models")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
                }
                .buttonStyle(.plain).pointerCursor(!loadingModels).disabled(loadingModels)
            }
        }
        if customModel || (!current.isEmpty && !isPreset) {
            ThemedTextField(placeholder: "Model ID", text: Binding(get: { profile.model ?? "" }, set: { profile.model = $0 }), autofocus: customModel)
        }
        if let modelError {
            Text(verbatim: modelError).font(.system(size: 11.5)).foregroundStyle(Pal.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if profile.provider == .openai {
            Text("Models are loaded from Codex on the machine selected below. Update Codex there if its model list is outdated.")
                .font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
        }
        Text("Leave on Default to use the CLI's own model. Names the CLI doesn't know make the request fail, so check them with `claude --help` or `codex --help` if unsure.")
            .font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
    }

    @MainActor
    private func reloadModels() async {
        loadedModels = []
        modelError = nil
        loadingModels = false
        guard profile.provider == .openai else { return }
        loadingModels = true
        do {
            let models = try await AIChatClient.listCodexModels(connection: connection, location: profile.location)
            guard !Task.isCancelled else { return }
            loadedModels = models
            loadingModels = false
        } catch {
            guard !Task.isCancelled else { return }
            modelError = error.localizedDescription
            loadingModels = false
        }
    }

    private var canSave: Bool { true }   // Empty names use the provider name.

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isNew ? "Add AI" : "Edit AI").font(.system(size: 16, weight: .bold)).foregroundStyle(Pal.text)

                    section(String(localized: "Name"), optional: true) {
                        ThemedTextField(placeholder: "e.g. Work Claude", text: $profile.name)
                    }

                    section(String(localized: "Which AI?")) {
                        Picker("", selection: $profile.provider) {
                            ForEach(AIAPIProvider.allCases) { p in
                                Label(p.shortName, lucideSymbol: p.icon).tag(p)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text("It must be installed and signed in on the machine you choose below.")
                            .font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
                    }

                    section(String(localized: "Model"), optional: true) {
                        modelPicker
                    }

                    if AppEnv.localTerminalEnabled {
                        section(String(localized: "Where should it run?")) {
                            locationCard(.remote, icon: "server.rack",
                                title: String(localized: "Run on the server"),
                                good: String(localized: "Use this if Claude or Codex is already installed and signed in on this server."),
                                caution: String(localized: "If it isn't installed there, you'll see “not installed on this server”. The AI runs with its normal safety limits."))
                            locationCard(.local, icon: "laptopcomputer",
                                title: String(localized: "Run on my Mac (via SSH)"),
                                good: String(localized: "Nothing to install on the server. Claude or Codex must be installed and signed in on this Mac."),
                                caution: nil)
                            if profile.location == .local {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(String(localized: "Important"), lucideSymbol: "exclamationmark.triangle.fill")
                                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Pal.red)
                                    Text("With “Run on my Mac”, the AI can run commands on this server by itself, using your login account's permissions. Ask carefully, and think twice before using it on a server you can't afford to break.")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Pal.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.red.opacity(0.45), lineWidth: 1))
                            }
                        }
                    }

                    section(String(localized: "Standing instructions"), optional: true) {
                        ThemedTextEditor(placeholder: "e.g. Answer in Korean. Ask me before suggesting anything that deletes files.", text: $profile.prompt)
                            .frame(minHeight: 90)
                        Text("Sent to the AI with every question. Use it for language, tone, or safety rules.")
                            .font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
                    }
                }
                .padding(20)
            }
            Divider().overlay(Pal.fill(0.08))
            HStack(spacing: 10) {
                if !isNew {
                    Button { confirmDelete = true } label: {
                        Text("Delete").font(.system(size: 13)).foregroundStyle(Pal.red)
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                Spacer()
                SecondaryButton(title: "Cancel") { onCancel() }
                PrimaryButton(title: isNew ? "Add" : "Save", enabled: canSave) {
                    var p = profile
                    p.name = p.name.trimmingCharacters(in: .whitespaces)
                    p.prompt = p.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    let m = (p.model ?? "").trimmingCharacters(in: .whitespaces); p.model = m.isEmpty ? nil : m
                    onSave(p)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: 600)
        .background(Pal.base)
        .task(id: "\(profile.provider.rawValue):\(profile.location.rawValue):\(modelRevision)") {
            await reloadModels()
        }
        .confirmationDialog(String(localized: "Delete this AI?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { onDelete() }
        } message: {
            Text("Past conversations are kept.")
        }
    }

    private func section<C: View>(_ title: String, optional: Bool = false, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Pal.text)
                if optional { Text("Optional").font(.system(size: 10)).foregroundStyle(Pal.overlay) }
            }
            content()
        }
    }

    private func locationCard(_ loc: AIChatExecutionLocation, icon: String, title: String, good: String, caution: String?) -> some View {
        let selected = profile.location == loc
        return Button { profile.location = loc } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(lucideSymbol: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Pal.tint : Pal.overlay)
                    Image(lucideSymbol: icon).foregroundStyle(Pal.subtext)
                    Text(verbatim: title).font(.system(size: 13, weight: .bold)).foregroundStyle(Pal.text)
                }
                Text(verbatim: good).font(.system(size: 12.5)).foregroundStyle(Pal.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let caution {
                    Text(verbatim: caution).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Pal.tint.opacity(0.12) : Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Pal.tint.opacity(0.55) : Pal.fill(0.10), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .focusable(false)
    }
}


/// Server picker: enter folders, attach paths, or select Work in This Folder.
struct AIPathPicker: View {
    let fs: RemoteFS
    let startPath: String?
    let workDir: String?
    let attachments: [String]
    let onUseFolder: (String) -> Void
    let onFollowTerminal: () -> Void
    let onToggleAttach: (String) -> Void

    @State private var path = ""
    @State private var entries: [RemoteFile] = []
    @State private var loading = true
    @State private var error: String?
    @State private var picked: Set<String> = []   // Local copy for immediate attachment-state feedback.

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a folder or files").font(.system(size: 14, weight: .bold)).foregroundStyle(Pal.text)
            Text("Open a folder and press “Use this folder” so the AI works there. Tap the paperclip to attach files or folders to your next question.")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                iconButton("arrow.up", help: String(localized: "Parent folder")) { go((path as NSString).deletingLastPathComponent) }
                    .disabled(path == "/" || path.isEmpty)
                iconButton("house", help: String(localized: "Home folder")) { Task { go(await fs.home()) } }
                Text(verbatim: path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            Group {
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Pal.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    Text("This folder is empty.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries) { e in row(e) }
                        }
                    }
                }
            }
            .frame(height: 230)
            .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                if workDir != nil {
                    SecondaryButton(title: "Follow terminal") { onFollowTerminal() }
                }
                Spacer()
                PrimaryButton(title: "Use this folder", enabled: !path.isEmpty && error == nil) { onUseFolder(path) }
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Pal.base)
        .onAppear {
            picked = Set(attachments)
            Task {
                let start = (startPath?.isEmpty == false && startPath != "~") ? startPath! : await fs.home()
                go(start)
            }
        }
    }

    private func row(_ e: RemoteFile) -> some View {
        let attached = picked.contains(e.path)
        return HStack(spacing: 8) {
            Button {
                if e.isDir { go(e.path) } else { toggle(e.path) }
            } label: {
                HStack(spacing: 8) {
                    Image(lucideSymbol: e.isDir ? "folder.fill" : "doc").foregroundStyle(e.isDir ? Pal.tint : Pal.subtext)
                        .frame(width: 16)
                    Text(verbatim: e.name).font(.system(size: 12.5)).foregroundStyle(Pal.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            Button { toggle(e.path) } label: {
                Image(lucideSymbol: attached ? "paperclip.circle.fill" : "paperclip")
                    .font(.system(size: 12)).foregroundStyle(attached ? Pal.tint : Pal.overlay)
            }
            .buttonStyle(.plain).pointerCursor()
            .help(attached ? String(localized: "Attached — click to remove") : String(localized: "Attach to the next question"))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(attached ? Pal.tint.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func toggle(_ p: String) {
        if picked.contains(p) { picked.remove(p) } else { picked.insert(p) }
        onToggleAttach(p)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    private func go(_ target: String) {
        let t = target.isEmpty ? "/" : target
        loading = true; error = nil
        Task {
            let r = await fs.list(t)
            await MainActor.run {
                switch r {
                case .success(let files):
                    path = t
                    entries = files.sorted {
                        if $0.isDir != $1.isDir { return $0.isDir }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .failure(let e):
                    path = t; entries = []; error = e.message
                }
                loading = false
            }
        }
    }
}
