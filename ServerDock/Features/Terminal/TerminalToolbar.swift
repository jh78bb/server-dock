import AppKit
import SwiftUI

/// SSH toolbar, similar to ZOC: copy current directory, upload here, create/open a file,
/// browse files, snippets, forwarding, host overview, clear screen, and new terminal. Can be disabled in settings.
private struct GitKey: Equatable { let cwd: String?; let live: Bool; let refresh: Int }

struct TerminalToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var conn: TerminalConn
    @ObservedObject private var settings = AppSettings.shared
    let tabId: Int
    let host: Host
    @State private var copied = false
    @State private var showHelp = false
    @State private var showGenerator = false
    @State private var showRsync = false
    @State private var showTmux = false
    @State private var showAICommand = false
    @State private var git: GitInfo?
    @State private var gitBranches: [String] = []
    @State private var gitRefresh = 0

    var body: some View {
        if settings.terminalToolbar {
            HStack(spacing: 6) {
                pathButton
                favoriteButton
                Spacer(minLength: 8)
                // 1) Files: New/Upload; browsing belongs to the right panel.
                iconButton("doc.badge.plus", help: String(localized: "New File Here")) {
                    model.requestNewFileAtTerminalCwd(tabId)
                }
                iconButton("square.and.arrow.up", help: String(localized: "Upload Files Here")) {
                    model.presentUploadToTerminal(tabId)
                }
                divider
                // 2) Commands: common queries/scripts/Git when in a repository.
                commandsMenu
                snippetMenu
                if let git { gitMenu(git) }
                divider
                // 3) AI: command generator/chat.
                iconButton("sparkles", help: String(localized: "AI Command Generator")) { showAICommand.toggle() }
                    .popover(isPresented: $showAICommand, arrowEdge: .bottom) {
                        AICommandPopover(model: model, host: host, tabId: tabId, directory: conn.cwd,
                                         onAgent: { showAICommand = false; model.presentAIPrompt(forTerminal: tabId) },
                                         onClose: { showAICommand = false })
                    }
                if !host.isLocal {
                    iconButton("bubble.left.and.bubble.right", help: String(localized: "AI Chat")) {
                        model.openHostAIChat(host)
                    }
                }
                divider
                // 4) Session: tmux/forwarding/overview.
                Button { showTmux.toggle() } label: {
                    Image(lucideSymbol: "rectangle.split.3x1").font(.system(size: 12, weight: .medium)).foregroundStyle(model.tmuxAuto[host.id] != nil ? Pal.tint : Pal.subtext)
                        .frame(width: 26, height: 26).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().tooltip(ToolbarGuide.tooltip("rectangle.split.3x1", isLocal: host.isLocal) ?? "")
                .popover(isPresented: $showTmux, arrowEdge: .bottom) { TmuxPanel(model: model, host: host, tabId: tabId) }
                if !host.isLocal {
                    iconButton("arrow.left.arrow.right", help: String(localized: "Port Forwarding")) {
                        model.openForwardPanel(host)
                    }
                }
                iconButton("gauge.with.dots.needle.33percent", help: String(localized: "Host Overview")) {
                    model.openHost(host)
                }
                divider
                // 5) Terminal: clear; new terminals use the panel + button.
                iconButton("eraser", help: String(localized: "Clear Screen")) {
                    model.sendTerminalText(tabId, "\u{0C}")   // Ctrl-L lets the shell redraw without interrupting the command being typed.
                }
                divider
                helpButton
            }
            .task(id: GitKey(cwd: conn.cwd, live: conn.phase == .live, refresh: gitRefresh)) {
                guard let cwd = conn.cwd, conn.phase == .live else { git = nil; gitBranches = []; return }
                let info = await GitInfo.fetch(host: host, cwd: cwd)
                if Task.isCancelled { return }
                git = info
                gitBranches = info == nil ? [] : await GitCommands.branches(host: host, cwd: cwd)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    /// Current directory: placeholder until OSC 7 reports it; click to copy the complete path.
    private var pathButton: some View {
        Button {
            guard let cwd = conn.cwd else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cwd, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Image(lucideSymbol: copied ? "checkmark" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Pal.green : host.accent)
                Group {
                    if let cwd = conn.cwd {
                        Text(verbatim: cwd).foregroundStyle(Pal.text)
                    } else {
                        Text("Detecting…").foregroundStyle(Pal.overlay)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .tooltip(conn.cwd == nil ? "" : (ToolbarGuide.tooltip("folder.fill", isLocal: host.isLocal) ?? String(localized: "Click to copy the current path")))
    }

    /// Toggle cwd in favorites pinned atop the right panel.
    private var favoriteButton: some View {
        let cwd = conn.cwd
        let fav = cwd.map { model.isFavorite($0, hostId: host.id) } ?? false
        return Button {
            if let cwd { model.toggleFavorite(path: cwd, isDir: true, hostId: host.id) }
        } label: {
            Image(lucideSymbol: fav ? "star.fill" : "star").font(.system(size: 12, weight: .medium))
                .foregroundStyle(fav ? Pal.yellow : Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(cwd != nil)
        .disabled(cwd == nil)
        .tooltip((fav ? String(localized: "Remove This Folder from Favorites") : String(localized: "Add This Folder to Favorites")) + "\n" + (ToolbarGuide.all(isLocal: host.isLocal).first { $0.symbol == "star" }?.detail ?? ""))
    }

    private var snippetMenu: some View {
        Menu {
            if model.snippets.isEmpty {
                Text("No scripts yet")
            } else {
                let groups = Dictionary(grouping: model.snippets, by: \.group)
                ForEach(groups.keys.sorted(), id: \.self) { g in
                    SwiftUI.Section(g.isEmpty ? String(localized: "Ungrouped") : g) {
                        ForEach(groups[g] ?? []) { s in
                            Button(s.name) { model.triggerSnippet(s) }
                        }
                    }
                }
            }
            Divider()
            Button("New Script") { model.showCreateSnippet = true }
        } label: {
            Image(lucideSymbol: "text.badge.plus").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .tooltip(ToolbarGuide.tooltip("text.badge.plus", isLocal: host.isLocal) ?? String(localized: "Scripts"))
    }

    /// Common read-only listing/disk/system/network commands run immediately on selection.
    /// Commands with variants, e.g. ls/df/du, use submenus.
    private var commandsMenu: some View {
        Menu {
            ForEach(QuickCommands.groups) { group in
                Menu {
                    ForEach(group.items) { item in
                        if item.variants.isEmpty {
                            Button { runQuick(item.title) } label: { Text(verbatim: "\(item.title)  —  \(item.detail)") }
                        } else {
                            Menu(item.title) {
                                ForEach(item.variants) { v in
                                    Button { runQuick(v.command) } label: { Text(verbatim: "\(v.command)  —  \(v.detail)") }
                                }
                            }
                        }
                    }
                } label: {
                    Label(group.title, lucideSymbol: group.symbol)
                }
            }
            Divider()
            Button { showGenerator = true } label: {
                Label("chmod / chown Generator…", lucideSymbol: "wand.and.stars")
            }
            Button { showRsync = true } label: {
                Label("rsync Command Generator…", lucideSymbol: "arrow.triangle.2.circlepath")
            }
        } label: {
            Image(lucideSymbol: "list.bullet.rectangle").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .tooltip(ToolbarGuide.tooltip("list.bullet.rectangle", isLocal: host.isLocal) ?? String(localized: "Common Commands"))
        .sheet(isPresented: $showGenerator) {
            PermissionCommandSheet(host: host, cwd: conn.cwd) { cmd, run in
                model.sendTerminalText(tabId, run ? cmd + "\n" : cmd)
            }
        }
        .background {
            Color.clear.sheet(isPresented: $showRsync) {
                RsyncCommandSheet(model: model, host: host, cwd: conn.cwd) { cmd, run in
                    model.sendTerminalText(tabId, run ? cmd + "\n" : cmd)
                }
            }
        }
    }

    /// Repository-only Git menu runs queries directly and inserts mutations for review.
    private func gitMenu(_ info: GitInfo) -> some View {
        Menu {
            Text(verbatim: info.branch + (info.ahead > 0 ? "  ↑\(info.ahead)" : "") + (info.behind > 0 ? "  ↓\(info.behind)" : "") + (info.isClean ? "  ✓" : "  ●\(info.changed + info.untracked)"))
            Divider()
            ForEach(GitCommands.groups) { group in
                Menu {
                    ForEach(group.items) { item in
                        Button {
                            model.sendTerminalText(tabId, item.run ? item.command + "\n" : item.command)
                        } label: { Text(verbatim: "\(item.command)  —  \(item.detail)") }
                    }
                } label: { Label(group.title, lucideSymbol: group.symbol) }
            }
            if !gitBranches.isEmpty {
                Menu {
                    ForEach(gitBranches, id: \.self) { b in
                        Button { model.sendTerminalText(tabId, "git switch \(b)") } label: {
                            Text(verbatim: b == info.branch ? "✓ \(b)" : b)
                        }
                    }
                } label: { Label(String(localized: "Switch Branch (typed, not run)"), lucideSymbol: "arrow.triangle.swap") }
            }
            Divider()
            Button { gitRefresh += 1 } label: { Label(String(localized: "Refresh Git Info"), lucideSymbol: "arrow.clockwise") }
        } label: {
            // Icon only avoids long branches displacing buttons; show name in menu/tooltip and a yellow dirty dot.
            Image(lucideSymbol: "arrow.triangle.branch").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.tint)
                .frame(width: 26, height: 26)
                .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if !info.isClean { Circle().fill(Pal.yellow).frame(width: 6, height: 6).offset(x: 1, y: -1) }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .tooltip(info.branch + (info.isClean ? "" : "  ●\(info.changed + info.untracked)") + "\n" + (ToolbarGuide.all(isLocal: host.isLocal).first { $0.symbol == "arrow.triangle.branch" }?.detail ?? ""))
    }

    private func runQuick(_ command: String) {
        model.sendTerminalText(tabId, command + "\n")
    }

    private var divider: some View {
        Rectangle().fill(Pal.fill(0.12)).frame(width: 1, height: 16).padding(.horizontal, 2)
    }

    /// Rightmost help button explains toolbar actions in a popover.
    private var helpButton: some View {
        Button { showHelp = true } label: {
            Image(lucideSymbol: "questionmark.circle").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .tooltip(String(localized: "What do these buttons do?"))
        .popover(isPresented: $showHelp, arrowEdge: .top) { ToolbarHelpView(isLocal: host.isLocal, hasGit: git != nil) }
    }

    private func iconButton(_ symbol: String, help: String, _ act: @escaping () -> Void) -> some View {
        let tip = ToolbarGuide.tooltip(symbol, isLocal: host.isLocal) ?? help
        return Button(action: act) {
            Image(lucideSymbol: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().tooltip(tip)
    }
}

/// Single source for help descriptions and hover tooltips.
enum ToolbarGuide {
    struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    /// List only visible actions: no local AI chat/forwarding; Git only in repositories.
    static func items(isLocal: Bool, hasGit: Bool) -> [Item] {
        all(isLocal: isLocal).filter { item in
            switch item.symbol {
            case "bubble.left.and.bubble.right", "arrow.left.arrow.right": return !isLocal
            case "arrow.triangle.branch": return hasGit
            default: return true
            }
        }
    }

    /// Icon-to-name/newline/description tooltip, or nil.
    static func tooltip(_ symbol: String, isLocal: Bool) -> String? {
        all(isLocal: isLocal).first { $0.symbol == symbol }.map { "\($0.title)\n\($0.detail)" }
    }

    static func all(isLocal: Bool) -> [Item] { [
        Item(symbol: "folder.fill", title: String(localized: "Current Path"),
             detail: String(localized: "Shows the terminal's current directory. Click to copy the full path.")),
        Item(symbol: "star", title: String(localized: "Favorite This Folder"),
             detail: String(localized: "Pin the current directory to the Favorites list at the top of the file panel for one-click access next time.")),
        Item(symbol: "doc.badge.plus", title: String(localized: "New File Here"),
             detail: String(localized: "Create a new file in the current directory and open it in the editor.")),
        Item(symbol: "square.and.arrow.up", title: String(localized: "Upload Files Here"),
             detail: String(localized: "Upload local files into the terminal's current directory.")),
        Item(symbol: "list.bullet.rectangle", title: String(localized: "Common Commands"),
             detail: String(localized: "Ready-made commands grouped by purpose (files, disk, system, network, services and logs, Docker, Git) that run in this terminal, plus the rsync Command Generator.")),
        Item(symbol: "text.badge.plus", title: String(localized: "Scripts"),
             detail: String(localized: "Insert or run a saved script in this terminal. To fill in variables and choose options first, click the script in the left Scripts list.")),
        Item(symbol: "arrow.triangle.branch", title: "Git",
             detail: String(localized: "Appears only in a Git repository folder. Read-only commands and fetch / pull run right away; commands that change the repository (add, commit, push, stash, switch) are only typed at the prompt so you can review them.")),
        Item(symbol: "sparkles", title: String(localized: "AI Command Generator"),
             detail: String(localized: "Describe what you want in plain words and the AI writes the command. Review or edit it, then Insert, Run or Copy — nothing runs until you choose. It also links to running a full AI agent on the server.")),
        Item(symbol: "bubble.left.and.bubble.right", title: String(localized: "AI Chat"),
             detail: String(localized: "Open a conversation with the AI about this server; suggested commands can be sent to the terminal.")),
        Item(symbol: "rectangle.split.3x1", title: String(localized: "tmux / zellij sessions"),
             detail: String(localized: "List, attach to and create tmux or zellij sessions on this server.")),
        Item(symbol: "arrow.left.arrow.right", title: String(localized: "Port Forwarding"),
             detail: String(localized: "Open the port forwarding panel for this host.")),
        Item(symbol: "gauge.with.dots.needle.33percent", title: String(localized: "Host Overview"),
             detail: String(localized: "Go to this host's overview tab (status, specs, monitoring).")),
        Item(symbol: "eraser", title: String(localized: "Clear Screen"),
             detail: String(localized: "Clear the terminal screen (same as Ctrl-L).")),
    ] }
}

/// Help popover lists each toolbar icon/name/description.
private struct ToolbarHelpView: View {
    /// Explain only currently visible actions, respecting local/Git availability.
    let isLocal: Bool
    let hasGit: Bool
    private var items: [ToolbarGuide.Item] { ToolbarGuide.items(isLocal: isLocal, hasGit: hasGit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Toolbar Guide").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(lucideSymbol: item.symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Pal.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Pal.solidBase)
    }
}

enum AIAgentProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: return "ChatGPT (Codex)"
        case .claude: return "Claude"
        }
    }
    var executable: String { rawValue }
    var installCommand: String {
        switch self {
        case .codex: return "npm install -g @openai/codex"
        case .claude: return "npm install -g @anthropic-ai/claude-code"
        }
    }
}

struct AIPromptContext: Identifiable {
    let id = UUID()
    let tabId: Int
    let hostName: String
    let directory: String?
}

struct AIPromptRequest {
    let tabId: Int
    let provider: AIAgentProvider
    let model: String?
    let continueSession: Bool
    let prompt: String

    var modelArgument: String {
        guard let model, !model.isEmpty else { return "" }
        return " --model '" + model.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Compose an initial prompt for Codex/Claude in the SSH terminal.
struct AIPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let context: AIPromptContext
    @State private var provider: AIAgentProvider = .codex
    @State private var modelChoice = "default"
    @State private var customModel = ""
    @State private var continueSession = true
    @State private var prompt = ""

    private var selectedModel: String? {
        let trimmed = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelChoice == "custom" && !trimmed.isEmpty ? trimmed : nil
    }

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (modelChoice != "custom" || selectedModel != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Pal.tint)
                    .frame(width: 38, height: 38)
                    .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Assistant").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                    Text("Send a task to the terminal agent").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.overlay).frame(width: 28, height: 28)
                        .background(Pal.fill(0.06), in: Circle())
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Close"))
            }

            terminalContext

            VStack(alignment: .leading, spacing: 8) {
                Text("Provider").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                HStack(spacing: 8) {
                    providerButton(.codex, icon: "circle.grid.2x2.fill")
                    providerButton(.claude, icon: "sparkle")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                ThemedDropdown(options: [
                    (value: "default", label: "CLI default"),
                    (value: "custom", label: "Custom model…")
                ], selection: $modelChoice)
                if modelChoice == "custom" {
                    ThemedTextField(placeholder: "Model ID", text: $customModel, autofocus: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                ThemedTextEditor(placeholder: "Describe what you want to do…", text: $prompt, autofocus: true)
                    .frame(height: 130)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue previous session").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    Text("Use the most recent session saved by this CLI.").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                ThemedToggle(isOn: $continueSession)
            }
            .padding(11)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))

            cliNotice

            HStack {
                Spacer()
                SecondaryButton(title: "Cancel") { dismiss() }
                PrimaryButton(title: "Run in Terminal", enabled: canRun) {
                    model.runAIPrompt(AIPromptRequest(tabId: context.tabId, provider: provider, model: selectedModel, continueSession: continueSession, prompt: prompt))
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Pal.solidBase)
    }

    private var terminalContext: some View {
        HStack(spacing: 8) {
            Image(lucideSymbol: "terminal").foregroundStyle(Pal.tint)
            Text(verbatim: context.hostName).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
            if let directory = context.directory {
                Text(verbatim: directory).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cliNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(lucideSymbol: "terminal.badge.exclamationmark").foregroundStyle(Pal.yellow).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("CLI is checked on the connected server when you run this task.")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                Text("If the CLI is missing, the terminal will show the install command below.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                Text(verbatim: provider.installCommand)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .background(Pal.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func providerButton(_ value: AIAgentProvider, icon: String) -> some View {
        let selected = provider == value
        return Button { provider = value } label: {
            HStack(spacing: 8) {
                Image(lucideSymbol: icon).font(.system(size: 13, weight: .medium))
                Text(verbatim: value.displayName).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if selected { Image(lucideSymbol: "checkmark.circle.fill").foregroundStyle(Pal.tint) }
            }
            .foregroundStyle(selected ? Pal.text : Pal.subtext)
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(selected ? Pal.tint.opacity(0.12) : Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Pal.tint.opacity(0.65) : Pal.fill(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor()
    }
}
