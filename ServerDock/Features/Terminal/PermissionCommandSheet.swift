import AppKit
import SwiftUI

/// chmod/chown generator builds commands from options for copy/insert/run.
/// This sheet only constructs strings; execution requires the user's explicit insert/run action.
struct PermissionCommandSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case chmod, chown
        var id: String { rawValue }
    }

    let host: Host
    let cwd: String?
    /// (command, run); false inserts at the prompt only.
    let onSend: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var kind: Kind = .chmod
    @State private var path = ""
    @State private var sudo = false
    @State private var recursive = false
    @State private var verbose = false
    // chmod's nine owner/group/other read/write/execute bits, ordered r/w/x.
    @State private var bits: [Bool] = [true, true, false, true, false, false, true, false, false]   // 644
    @State private var dirExecOnly = false   // Recursive executable-directory-only permission uses X.
    // chown
    @State private var owner = ""
    @State private var group = ""
    @State private var noDereference = false

    private var accent: Color { host.accent }

    // MARK: Command generation

    private var octal: String {
        (0..<3).map { i in
            String((bits[i * 3] ? 4 : 0) + (bits[i * 3 + 1] ? 2 : 0) + (bits[i * 3 + 2] ? 1 : 0))
        }.joined()
    }

    private func setOctal(_ o: String) {
        let digits = o.compactMap { $0.wholeNumberValue }
        guard digits.count == 3, digits.allSatisfy({ $0 <= 7 }) else { return }
        for (i, d) in digits.enumerated() {
            bits[i * 3] = d & 4 != 0; bits[i * 3 + 1] = d & 2 != 0; bits[i * 3 + 2] = d & 1 != 0
        }
    }

    private var symbolic: String {
        let who = ["u", "g", "o"]
        return (0..<3).map { i in
            let r = bits[i * 3] ? "r" : "", w = bits[i * 3 + 1] ? "w" : ""
            let x = bits[i * 3 + 2] ? (dirExecOnly && recursive ? "X" : "x") : ""
            return "\(who[i])=\(r)\(w)\(x)"
        }.joined(separator: ",")
    }

    /// Single-quote values containing spaces/special characters.
    private func quoted(_ s: String) -> String {
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~+@%:,=".contains($0) }
        return safe ? s : AppModel.shellQuote(s)
    }

    private var targetText: String { path.trimmingCharacters(in: .whitespaces) }

    private var command: String {
        var parts: [String] = []
        if sudo { parts.append("sudo") }
        parts.append(kind.rawValue)
        if recursive { parts.append("-R") }
        if verbose { parts.append("-v") }
        switch kind {
        case .chmod:
            parts.append(dirExecOnly && recursive ? symbolic : octal)
        case .chown:
            if noDereference { parts.append("-h") }
            let o = owner.trimmingCharacters(in: .whitespaces), g = group.trimmingCharacters(in: .whitespaces)
            parts.append(g.isEmpty ? o : "\(o):\(g)")
        }
        parts.append(targetText.isEmpty ? "<path>" : quoted(targetText))
        return parts.joined(separator: " ")
    }

    private var problem: String? {
        if targetText.isEmpty { return String(localized: "Enter a file or folder path.") }
        if kind == .chown {
            let o = owner.trimmingCharacters(in: .whitespaces), g = group.trimmingCharacters(in: .whitespaces)
            if o.isEmpty && g.isEmpty { return String(localized: "Enter an owner, a group, or both.") }
            let ok = { (s: String) in s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } }
            if !ok(o) || !ok(g) { return String(localized: "User and group names can only use letters, numbers, . _ -") }
        }
        return nil
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(lucideSymbol: "wand.and.stars").foregroundStyle(accent)
                Text("Command Generator").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }

            field(String(localized: "Path")) {
                HStack(spacing: 6) {
                    TextField("e.g. ./app.sh", text: $path).textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                    if let cwd, !cwd.isEmpty {
                        Button { path = cwd } label: {
                            Text("Current Folder").font(.system(size: 11)).foregroundStyle(accent)
                        }
                        .buttonStyle(.plain).pointerCursor()
                        .help(cwd)
                    }
                }
            }

            if kind == .chmod { chmodOptions } else { chownOptions }

            HStack(spacing: 16) {
                toggle(String(localized: "Recursive (-R)"), $recursive)
                toggle(String(localized: "Verbose (-v)"), $verbose)
                toggle("sudo", $sudo)
                Spacer()
            }

            preview

            HStack(spacing: 8) {
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Pal.yellow)
                } else if kind == .chmod, octal == "777" {
                    Text("777 lets everyone read, write and run this. Avoid it on servers.")
                        .font(.system(size: 11)).foregroundStyle(Pal.yellow)
                } else if recursive {
                    Text("-R changes everything inside the folder too. Double-check the path.")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .disabled(problem != nil)
                Button("Insert") { onSend(command, false); dismiss() }.disabled(problem != nil)
                Button("Run") { onSend(command, true); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var chmodOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach([String(localized: "Read"), String(localized: "Write"), String(localized: "Execute")], id: \.self) {
                        Text($0).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    }
                }
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        Text([String(localized: "Owner"), String(localized: "Group"), String(localized: "Others")][row])
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        ForEach(0..<3, id: \.self) { col in
                            Toggle("", isOn: $bits[row * 3 + col]).labelsHidden().toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Octal").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                TextField("", text: Binding(get: { octal }, set: { setOctal($0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                    .font(.system(size: 12, design: .monospaced))
                Text(verbatim: symbolic).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
            }
            HStack(spacing: 6) {
                ForEach([("644", "rw-r--r--"), ("755", "rwxr-xr-x"), ("600", "rw-------"),
                         ("700", "rwx------"), ("664", "rw-rw-r--"), ("775", "rwxrwxr-x")], id: \.0) { code, hint in
                    Button { setOctal(code) } label: {
                        Text(verbatim: code).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(octal == code ? accent.opacity(0.18) : Pal.fill(0.06), in: Capsule())
                            .foregroundStyle(octal == code ? accent : Pal.subtext)
                    }
                    .buttonStyle(.plain).pointerCursor().help(hint)
                }
            }
            if recursive {
                toggle(String(localized: "Execute only on folders (X) — keeps regular files non-executable"), $dirExecOnly)
            }
        }
    }

    private var chownOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                field(String(localized: "Owner")) {
                    TextField("e.g. www-data", text: $owner).textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
                field(String(localized: "Group")) {
                    TextField("e.g. www-data", text: $group).textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            HStack(spacing: 6) {
                ForEach(["root", "www-data", "nginx", "ubuntu", "docker"], id: \.self) { name in
                    Button { owner = name; group = name } label: {
                        Text(verbatim: name).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Pal.fill(0.06), in: Capsule()).foregroundStyle(Pal.subtext)
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .help(String(localized: "Use as owner and group"))
                }
            }
            toggle(String(localized: "Change the symlink itself, not its target (-h)"), $noDereference)
        }
    }

    private var preview: some View {
        HStack(spacing: 8) {
            Text(verbatim: "$").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.overlay)
            Text(verbatim: command).font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Pal.textBright).textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.35), lineWidth: 1))
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            content()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(title).font(.system(size: 12)).foregroundStyle(Pal.subtext) }
            .toggleStyle(.checkbox)
    }
}
