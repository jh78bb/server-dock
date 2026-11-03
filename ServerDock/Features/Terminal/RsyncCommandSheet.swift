import AppKit
import SwiftUI

/// rsync generator offers copy/insert/run for option-built commands.
/// Construct strings only; transfers occur only after the user inserts/runs in the terminal.
/// Enable dry-run (-n) by default to preview changes without transferring/deleting.
struct RsyncCommandSheet: View {
    enum Mode: String, CaseIterable {
        case local, push, pull
        var title: String {
            switch self {
            case .local: return String(localized: "On this machine")
            case .push: return String(localized: "Send to another server")
            case .pull: return String(localized: "Fetch from another server")
            }
        }
    }
    enum Progress: String { case none, perFile, overall }

    @ObservedObject var model: AppModel
    let host: Host
    let cwd: String?
    /// (command, run); false inserts only.
    let onSend: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var mode: Mode = .push
    @State private var source = ""
    @State private var dest = ""
    // Remote.
    @State private var remoteUser = ""
    @State private var remoteHost = ""
    @State private var remotePort = ""
    @State private var identity = ""
    // Options.
    @State private var archive = true
    @State private var verbose = true
    @State private var compress = true
    @State private var human = true
    @State private var dryRun = true            // Default to dry-run against accidental transfer/deletion.
    @State private var deleteExtra = false
    @State private var partial = true
    @State private var checksum = false
    @State private var updateOnly = false
    @State private var ignoreExisting = false
    @State private var itemize = true
    @State private var progress: Progress = .overall
    @State private var excludes = ""
    @State private var bwlimit = ""
    @State private var remoteSudo = false

    private var accent: Color { host.accent }

    // MARK: Command generation

    private func q(_ s: String) -> String {
        let safe = !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~+@%:,=".contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private var remoteSpec: String {
        let u = remoteUser.trimmingCharacters(in: .whitespaces), h = remoteHost.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? h : "\(u)@\(h)"
    }

    private var excludeList: [String] {
        excludes.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var command: String {
        var parts = ["rsync"]
        var short = ""
        if archive { short += "a" }
        if verbose { short += "v" }
        if compress { short += "z" }
        if human { short += "h" }
        if dryRun { short += "n" }
        if checksum { short += "c" }
        if updateOnly { short += "u" }
        if itemize { short += "i" }
        if !short.isEmpty { parts.append("-" + short) }
        if partial { parts.append("--partial") }
        switch progress {
        case .none: break
        case .perFile: parts.append("--progress")
        case .overall: parts.append("--info=progress2")
        }
        if deleteExtra { parts.append("--delete") }
        if ignoreExisting { parts.append("--ignore-existing") }
        let bw = bwlimit.trimmingCharacters(in: .whitespaces)
        if !bw.isEmpty { parts.append("--bwlimit=\(q(bw))") }
        for e in excludeList { parts.append("--exclude=\(q(e))") }
        if mode != .local {
            var ssh = "ssh"
            let port = remotePort.trimmingCharacters(in: .whitespaces)
            if !port.isEmpty { ssh += " -p \(port)" }
            let id = identity.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { ssh += " -i \(id)" }
            if ssh != "ssh" { parts.append("-e"); parts.append(q(ssh)) }
            if remoteSudo { parts.append("--rsync-path=" + q("sudo rsync")) }
        }
        let src = source.trimmingCharacters(in: .whitespaces), dst = dest.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .local:
            parts.append(src.isEmpty ? "<source>" : q(src)); parts.append(dst.isEmpty ? "<destination>" : q(dst))
        case .push:
            parts.append(src.isEmpty ? "<source>" : q(src))
            parts.append(q("\(remoteSpec.isEmpty ? "<user@host>" : remoteSpec):\(dst)"))
        case .pull:
            parts.append(q("\(remoteSpec.isEmpty ? "<user@host>" : remoteSpec):\(src)"))
            parts.append(dst.isEmpty ? "<destination>" : q(dst))
        }
        return parts.joined(separator: " ")
    }

    private var problem: String? {
        if source.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the source path.") }
        if dest.trimmingCharacters(in: .whitespaces).isEmpty && mode != .push { return String(localized: "Enter the destination path.") }
        if mode == .push && dest.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the destination path on the other server.") }
        if mode != .local && remoteHost.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the other server's address.") }
        return nil
    }

    /// Explain easily overlooked settings.
    private var notes: [(String, Color)] {
        var n: [(String, Color)] = []
        let src = source.trimmingCharacters(in: .whitespaces)
        if deleteExtra {
            n.append((String(localized: "--delete removes files at the destination that don't exist at the source. Keep “Preview” on and read the list first."), Pal.red))
        }
        if !src.isEmpty, mode != .pull {
            if src.hasSuffix("/") { n.append((String(localized: "A trailing / on the source copies the folder's contents; without it the folder itself is created inside the destination."), Pal.overlay)) }
            else if !src.contains("*") { n.append((String(localized: "No trailing / on the source: the folder itself is created inside the destination."), Pal.overlay)) }
        }
        if !dryRun { n.append((String(localized: "Preview is off — this run will really transfer files."), Pal.yellow)) }
        if progress == .overall { n.append((String(localized: "Overall progress needs rsync 3.1 or newer on this machine (the rsync that ships with macOS doesn't have it — choose “Per file” there)."), Pal.overlay)) }
        if mode != .local { n.append((String(localized: "The transfer connects from this machine's shell to the other server with ssh, so it needs a key or agent that server accepts (no password prompt inside the terminal is fine)."), Pal.overlay)) }
        return n
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(lucideSymbol: "arrow.triangle.2.circlepath").foregroundStyle(accent)
                Text("rsync Command Generator").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }
                    .buttonStyle(.plain).pointerCursor()
            }

            SegmentedControl(options: Mode.allCases.map { (value: $0, verbatim: $0.title) }, selection: $mode)

            pathFields
            if mode != .local { remoteFields }
            optionsGrid
            excludeAndLimit
            preview

            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                Text(verbatim: n.0).font(.system(size: 11)).foregroundStyle(n.1).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Pal.yellow) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                    .disabled(problem != nil)
                Button("Insert") { onSend(command, false); dismiss() }.disabled(problem != nil)
                Button(dryRun ? String(localized: "Run Preview") : String(localized: "Run")) { onSend(command, true); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { if source.isEmpty, mode == .push || mode == .local, let cwd, !cwd.isEmpty { source = cwd.hasSuffix("/") ? cwd : cwd + "/" } }
    }

    private var pathFields: some View {
        HStack(alignment: .top, spacing: 12) {
            field(mode == .pull ? String(localized: "Source (on the other server)") : String(localized: "Source (on this machine)")) {
                TextField("e.g. /var/www/site/", text: $source).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            }
            field(mode == .push ? String(localized: "Destination (on the other server)") : String(localized: "Destination (on this machine)")) {
                TextField("e.g. /backup/site/", text: $dest).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Other server").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Menu {
                    ForEach(model.hosts.filter { !$0.isRDP && !$0.isLocal && $0.id != host.id }) { h in
                        Button(h.name) {
                            remoteUser = h.ssh?.user ?? ""; remoteHost = h.ssh?.host ?? ""
                            remotePort = (h.ssh?.port ?? 22) == 22 ? "" : String(h.ssh?.port ?? 22)
                            if let k = h.ssh?.keyPath, !k.isEmpty { identity = k }
                        }
                    }
                } label: { Label("Pick a saved host", lucideSymbol: "server.rack").font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            HStack(spacing: 10) {
                field(String(localized: "User")) { TextField("user", text: $remoteUser).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)) }
                field(String(localized: "Address")) { TextField("host.example.com", text: $remoteHost).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)) }
                field(String(localized: "Port")) { TextField("22", text: $remotePort).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)) }.frame(width: 70)
            }
            HStack(spacing: 10) {
                field(String(localized: "Key file (-i)")) { TextField("~/.ssh/id_ed25519", text: $identity).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)) }
                Toggle(isOn: $remoteSudo) { Text("sudo rsync on the other server").font(.system(size: 12)).foregroundStyle(Pal.subtext) }
                    .toggleStyle(.checkbox).padding(.top, 14)
            }
        }
    }

    private var optionsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Options").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 7) {
                toggle(String(localized: "Preview only (-n) — nothing is changed"), $dryRun)
                toggle(String(localized: "Archive (-a): keep permissions, times, links"), $archive)
                toggle(String(localized: "Verbose (-v)"), $verbose)
                toggle(String(localized: "Compress (-z)"), $compress)
                toggle(String(localized: "Human-readable sizes (-h)"), $human)
                toggle(String(localized: "List what changes (-i)"), $itemize)
                toggle(String(localized: "Keep partial files (--partial): resume big files"), $partial)
                toggle(String(localized: "Compare by checksum (-c): slower"), $checksum)
                toggle(String(localized: "Skip files newer at the destination (-u)"), $updateOnly)
                toggle(String(localized: "Skip files that already exist (--ignore-existing)"), $ignoreExisting)
                toggle(String(localized: "Delete extra files at the destination (--delete)"), $deleteExtra)
            }
            HStack(spacing: 8) {
                Text("Progress").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                SegmentedControl(options: [(value: Progress.none, label: LocalizedStringKey("None")),
                                           (value: Progress.perFile, label: LocalizedStringKey("Per file")),
                                           (value: Progress.overall, label: LocalizedStringKey("Overall"))], selection: $progress)
                    .frame(width: 240)
                Spacer()
            }
        }
    }

    private var excludeAndLimit: some View {
        HStack(alignment: .top, spacing: 12) {
            field(String(localized: "Exclude (one per line or comma-separated)")) {
                TextField("e.g. node_modules, .git, *.log", text: $excludes, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            }
            field(String(localized: "Speed limit")) {
                TextField("e.g. 5m", text: $bwlimit).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            }.frame(width: 110)
        }
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "$").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.overlay)
            Text(verbatim: command).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Pal.textBright).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.35), lineWidth: 1))
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            content().padding(.horizontal, 10).padding(.vertical, 7).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(title).font(.system(size: 12)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true) }
            .toggleStyle(.checkbox)
    }
}
