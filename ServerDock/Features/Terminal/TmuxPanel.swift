import SwiftUI

/// One remote tmux/zellij session.
struct MuxSession: Identifiable, Hashable {
    enum Kind: String { case tmux, zellij }
    let kind: Kind
    let name: String
    var windows: Int? = nil
    var attached: Int = 0
    var id: String { kind.rawValue + ":" + name }
}

enum MuxCommands {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static let listScript = """
    export LC_ALL=C
    command -v tmux >/dev/null 2>&1 && echo "HAS tmux"
    command -v zellij >/dev/null 2>&1 && echo "HAS zellij"
    tmux ls -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null | sed 's/^/T /'
    zellij ls -s 2>/dev/null | sed 's/^/Z /'
    """

    static func parse(_ out: String) -> (tmux: Bool, zellij: Bool, sessions: [MuxSession]) {
        var tmux = false, zellij = false
        var list: [MuxSession] = []
        for raw in out.split(whereSeparator: \.isNewline) {
            let l = String(raw)
            if l == "HAS tmux" { tmux = true }
            else if l == "HAS zellij" { zellij = true }
            else if l.hasPrefix("T ") {
                let f = l.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 3 { list.append(MuxSession(kind: .tmux, name: f[0], windows: Int(f[1]), attached: Int(f[2]) ?? 0)) }
            } else if l.hasPrefix("Z ") {
                let n = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { list.append(MuxSession(kind: .zellij, name: n)) }
            }
        }
        return (tmux, zellij, list)
    }

    /// Attach command switches clients rather than nesting inside tmux.
    static func attach(_ s: MuxSession) -> String {
        switch s.kind {
        case .tmux: return "if [ -n \"$TMUX\" ]; then tmux switch-client -t \(q(s.name)); else tmux attach -t \(q(s.name)); fi"
        case .zellij: return "zellij attach \(q(s.name))"
        }
    }
    static func create(_ kind: MuxSession.Kind, name: String) -> String {
        switch kind {
        case .tmux: return "if [ -n \"$TMUX\" ]; then tmux new -d -s \(q(name)) 2>/dev/null; tmux switch-client -t \(q(name)); else tmux new -A -s \(q(name)); fi"
        case .zellij: return "zellij attach -c \(q(name))"
        }
    }
    static func kill(_ s: MuxSession) -> String {
        switch s.kind {
        case .tmux: return "tmux kill-session -t \(q(s.name)) 2>&1"
        case .zellij: return "zellij kill-session \(q(s.name)) 2>&1; zellij delete-session \(q(s.name)) 2>&1"
        }
    }
    /// Automatic new-terminal attachment; no-op when tmux is missing.
    static func autoAttach(_ name: String) -> String {
        "command -v tmux >/dev/null 2>&1 && [ -z \"$TMUX\" ] && tmux new -A -s \(q(name))"
    }
}

/// Terminal tmux/zellij popover: list/attach/create/terminate and auto-attach preference.
struct TmuxPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    let tabId: Int
    @State private var sessions: [MuxSession] = []
    @State private var hasTmux = false
    @State private var hasZellij = false
    @State private var loading = true
    @State private var newName = ""
    @State private var newKind: MuxSession.Kind = .tmux
    @State private var pendingKill: MuxSession?
    @State private var autoName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Terminal Sessions").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { load() } label: { Image(lucideSymbol: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(Pal.subtext) }.buttonStyle(.plain).pointerCursor()
            }
            if !loading, !hasTmux, !hasZellij {
                Text("tmux and zellij aren't installed on this server. Install one (for example: sudo apt install tmux) to keep sessions alive after a disconnect.")
                    .font(.system(size: 11.5)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true)
            } else {
                if sessions.isEmpty, !loading {
                    Text("No running sessions.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                }
                ForEach(sessions) { s in row(s) }
                Divider().overlay(Pal.fill(0.08))
                HStack(spacing: 6) {
                    if hasTmux && hasZellij {
                        SegmentedControl(options: [(value: MuxSession.Kind.tmux, verbatim: "tmux"), (value: MuxSession.Kind.zellij, verbatim: "zellij")], selection: $newKind).frame(width: 130)
                    }
                    ThemedTextField(verbatim: "main", text: $newName) { create() }
                    Button { create() } label: {
                        Text("New / Attach").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.tint).padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)).fixedSize()
                    }.buttonStyle(.plain).pointerCursor().disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if hasTmux {
                    Divider().overlay(Pal.fill(0.08))
                    Toggle(isOn: Binding(get: { !autoName.isEmpty }, set: { on in
                        autoName = on ? (autoName.isEmpty ? "main" : autoName) : ""
                        model.setTmuxAuto(hostId: host.id, name: autoName)
                    })) { Text("Attach a tmux session automatically in new terminals").font(.system(size: 12)).foregroundStyle(Pal.subtext) }
                        .toggleStyle(.checkbox)
                    if !autoName.isEmpty {
                        HStack(spacing: 6) {
                            Text("Session name").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                            TextField("main", text: $autoName, onCommit: { model.setTmuxAuto(hostId: host.id, name: autoName) })
                                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6)).frame(width: 140)
                        }
                    }
                }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(Pal.yellow).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16).frame(width: 360)
        .onAppear { autoName = model.tmuxAuto[host.id] ?? ""; load() }
        .confirmationDialog(String(localized: "Kill session “\(pendingKill?.name ?? "")”?"), isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }), titleVisibility: .visible) {
            Button("Kill Session", role: .destructive) { if let s = pendingKill { kill(s) }; pendingKill = nil }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: { Text("Everything running inside the session stops.") }
    }

    private func row(_ s: MuxSession) -> some View {
        HStack(spacing: 8) {
            Image(lucideSymbol: s.kind == .tmux ? "rectangle.split.3x1" : "square.split.2x2").font(.system(size: 11)).foregroundStyle(Pal.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: s.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                Text(verbatim: s.kind.rawValue + (s.windows.map { " · \($0) " + String(localized: "windows") } ?? "") + (s.attached > 0 ? " · " + String(localized: "attached") : ""))
                    .font(.system(size: 10.5)).foregroundStyle(Pal.overlay)
            }
            Spacer(minLength: 6)
            Button { model.sendTerminalText(tabId, MuxCommands.attach(s) + "\n") } label: {
                Text("Attach").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.tint).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).pointerCursor()
            Button { pendingKill = s } label: { Image(lucideSymbol: "xmark").font(.system(size: 10)).foregroundStyle(Pal.overlay).frame(width: 20, height: 20) }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Kill session"))
        }
    }

    private func load() {
        guard let ssh = host.ssh else { loading = false; return }
        loading = true
        Task {
            let r = await RemoteFS(ssh).run(MuxCommands.listScript, timeout: 15)
            let p = MuxCommands.parse(String(decoding: r.data, as: UTF8.self))
            hasTmux = p.tmux; hasZellij = p.zellij; sessions = p.sessions
            if !hasTmux && hasZellij { newKind = .zellij }
            loading = false
        }
    }

    private func create() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { message = String(localized: "Use letters, numbers, - _ . for the session name."); return }
        message = nil
        let kind: MuxSession.Kind = hasTmux && hasZellij ? newKind : (hasTmux ? .tmux : .zellij)
        model.sendTerminalText(tabId, MuxCommands.create(kind, name: n) + "\n")
        newName = ""
    }

    private func kill(_ s: MuxSession) {
        guard let ssh = host.ssh else { return }
        Task {
            _ = await RemoteFS(ssh).run(MuxCommands.kill(s), timeout: 15)
            load()
        }
    }
}
