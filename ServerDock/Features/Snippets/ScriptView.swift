import SwiftUI

/// Script-tab variable values, target terminal, and execution options survive tab switching.
@MainActor
final class ScriptSession: ObservableObject {
    let snippetId: String
    @Published var values: [String: String] = [:]
    @Published var targetTabId: Int?
    @Published var run = true              // true executes with Enter; false inserts only.
    @Published var clearFirst = false      // Clear with Ctrl-L before execution.
    @Published var status: String?         // Last execution summary.
    @Published var statusOK = true

    init(snippetId: String) {
        self.snippetId = snippetId
        values = UserDefaults.standard.dictionary(forKey: Self.valuesKey)?[snippetId] as? [String: String] ?? [:]
        let o = UserDefaults.standard.dictionary(forKey: Self.optionsKey)?[snippetId] as? [String: Bool] ?? [:]
        run = o["run"] ?? true; clearFirst = o["clear"] ?? false
    }

    private static let valuesKey = "scriptVariableValues"
    private static let optionsKey = "scriptOptions"
    private static let recentsKey = "scriptVariableRecents"

    /// Remember variable values by name across scripts, e.g. host/port.
    static func recents(for name: String) -> [String] {
        (UserDefaults.standard.dictionary(forKey: recentsKey)?[name] as? [String]) ?? []
    }

    /// Remember values/options after execution.
    func remember(specs: [Snippet.VariableSpec]) {
        let d = UserDefaults.standard
        var all = d.dictionary(forKey: Self.valuesKey) ?? [:]; all[snippetId] = values; d.set(all, forKey: Self.valuesKey)
        var opts = d.dictionary(forKey: Self.optionsKey) ?? [:]; opts[snippetId] = ["run": run, "clear": clearFirst]; d.set(opts, forKey: Self.optionsKey)
        var rec = d.dictionary(forKey: Self.recentsKey) ?? [:]
        for s in specs {
            guard let v = values[s.name], !v.isEmpty else { continue }
            var list = (rec[s.name] as? [String] ?? []).filter { $0 != v }
            list.insert(v, at: 0); rec[s.name] = Array(list.prefix(6))
        }
        d.set(rec, forKey: Self.recentsKey)
    }

    /// Fill unset variables from defaults or remembered values.
    func prefill(specs: [Snippet.VariableSpec]) {
        for s in specs where (values[s.name] ?? "").isEmpty {
            if s.isChoice || !s.defaultValue.isEmpty { values[s.name] = s.defaultValue }
            else if let r = Self.recents(for: s.name).first { values[s.name] = r }
        }
        for s in specs where s.isChoice && !s.options.contains(values[s.name] ?? "") { values[s.name] = s.defaultValue }
    }
}

struct ScriptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject var session: ScriptSession
    @ObservedObject private var theme = ThemeManager.shared
    @State private var confirmDelete = false

    private var snippet: Snippet? { model.snippets.first { $0.id == session.snippetId } }

    var body: some View {
        Group {
            if let sn = snippet { content(sn) } else {
                VStack(spacing: 8) {
                    Image(lucideSymbol: "questionmark.folder").font(.system(size: 28)).foregroundStyle(Pal.overlay)
                    Text("This script no longer exists.").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Pal.solidBase)
    }

    private func content(_ sn: Snippet) -> some View {
        let specs = Snippet.variableSpecs(in: sn.content)
        let resolved = Snippet.substitute(sn.content, values: session.values)
        let missing = specs.filter { (session.values[$0.name] ?? "").isEmpty }
        let terminals = model.scriptTargets
        let target = terminals.first { $0.id == session.targetTabId }
        let canSend = target != nil && missing.isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(sn)
                if !specs.isEmpty { variablesCard(specs) }
                previewCard(sn, specs: specs)
                optionsCard(terminals: terminals, target: target)
                actionBar(sn, specs: specs, resolved: resolved, canSend: canSend, missing: missing, target: target)
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear {
            session.prefill(specs: specs)
            if session.targetTabId == nil || !terminals.contains(where: { $0.id == session.targetTabId }) {
                session.targetTabId = terminals.count == 1 ? terminals[0].id : nil
            }
        }
        .onChange(of: terminals.map(\.id)) { _, ids in
            if let t = session.targetTabId, !ids.contains(t) { session.targetTabId = nil }
            if session.targetTabId == nil, ids.count == 1 { session.targetTabId = ids[0] }
        }
        .alert(String(localized: "Delete this script?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { model.deleteSnippet(sn); model.closeScriptTab(session.snippetId) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    // MARK: Components

    private func header(_ sn: Snippet) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(lucideSymbol: "chevron.left.forwardslash.chevron.right").font(.system(size: 18)).foregroundStyle(Pal.tint).frame(width: 30, height: 30)
                .background(Pal.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: sn.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                Text(verbatim: "\(sn.displayGroup) · " + String(localized: "\(sn.content.split(whereSeparator: \.isNewline).count) lines"))
                    .font(.system(size: 11.5)).foregroundStyle(Pal.overlay)
            }
            Spacer()
            Button { model.editingSnippet = sn } label: { Label(String(localized: "Edit"), lucideSymbol: "pencil").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(Pal.subtext).pointerCursor()
            Menu {
                Button(String(localized: "Copy Body")) { model.copySnippet(sn) }
                Button(String(localized: "Duplicate")) { model.duplicateSnippet(sn) }
                Divider()
                Button(String(localized: "Delete"), role: .destructive) { confirmDelete = true }
            } label: { Image(lucideSymbol: "ellipsis").font(.system(size: 13)).foregroundStyle(Pal.subtext).frame(width: 26, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func card<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.subtext)
            c()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.fill(0.08), lineWidth: 1))
    }

    private func variablesCard(_ specs: [Snippet.VariableSpec]) -> some View {
        card("Variables") {
            VStack(spacing: 9) {
                ForEach(specs, id: \.name) { s in
                    HStack(spacing: 10) {
                        Text(verbatim: s.name).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Pal.tint)
                            .frame(width: 120, alignment: .trailing)
                        if s.isChoice {
                            SegmentedControl(options: s.options.map { (value: $0, verbatim: $0) }, selection: binding(s.name))
                        } else {
                            ThemedTextField(verbatim: s.defaultValue.isEmpty ? String(localized: "Value") : s.defaultValue, text: binding(s.name))
                            let rec = ScriptSession.recents(for: s.name)
                            if !rec.isEmpty {
                                Menu {
                                    ForEach(rec, id: \.self) { r in Button(r) { session.values[s.name] = r } }
                                } label: { Image(lucideSymbol: "clock.arrow.circlepath").font(.system(size: 12)) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(String(localized: "Recent values"))
                            }
                        }
                    }
                }
            }
            Text("Tip: write {{name=default}} for a default value or {{env=dev|staging|prod}} for a choice in the script body.")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { session.values[name] ?? "" }, set: { session.values[name] = $0 })
    }

    private func previewCard(_ sn: Snippet, specs: [Snippet.VariableSpec]) -> some View {
        card("Script") {
            Text(highlighted(sn.content, specs: specs))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Highlight filled values, showing missing {{placeholders}} in yellow.
    private func highlighted(_ content: String, specs: [Snippet.VariableSpec]) -> AttributedString {
        var out = AttributedString()
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([^{}]+?)\\s*\\}\\}") else { return AttributedString(content) }
        let ns = content as NSString; var pos = 0
        func plain(_ s: String) -> AttributedString { var a = AttributedString(s); a.foregroundColor = Pal.text; return a }
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)))
            let raw = ns.substring(with: m.range(at: 1))
            let name = raw.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            let v = session.values[name] ?? ""
            var a = AttributedString(v.isEmpty ? ns.substring(with: m.range) : v)
            a.foregroundColor = v.isEmpty ? Pal.yellow : Pal.tint; a.font = .system(size: 12, weight: .semibold, design: .monospaced)
            out += a; pos = m.range.location + m.range.length
        }
        out += plain(ns.substring(from: pos))
        return out
    }

    private func optionsCard(terminals: [ScriptTarget], target: ScriptTarget?) -> some View {
        card("Run in") {
            HStack(spacing: 10) {
                if terminals.isEmpty {
                    Text("No terminal is open. Connect to a server first.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    Menu {
                        ForEach(model.hosts.filter { !$0.isRDP }) { h in Button(h.name) { model.openHostTerminal(h) } }
                    } label: { Label(String(localized: "Open Terminal"), lucideSymbol: "terminal").font(.system(size: 12)) }
                        .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Menu {
                        ForEach(terminals) { t in Button(t.title) { session.targetTabId = t.id } }
                    } label: {
                        HStack(spacing: 6) {
                            Image(lucideSymbol: "terminal").font(.system(size: 11))
                            Text(verbatim: target?.title ?? String(localized: "Choose a terminal…")).font(.system(size: 12.5))
                            Image(lucideSymbol: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                        .foregroundStyle(target == nil ? Pal.yellow : Pal.text).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Spacer()
            }
            HStack(spacing: 18) {
                SegmentedControl(options: [(value: true, label: LocalizedStringKey("Run")), (value: false, label: LocalizedStringKey("Type only"))], selection: $session.run)
                    .frame(width: 180)
                Toggle("Clear screen first", isOn: $session.clearFirst).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            Text(session.run ? "Sends the script and presses Return." : "Types the script at the prompt without pressing Return, so you can review it first.")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        }
    }

    private func actionBar(_ sn: Snippet, specs: [Snippet.VariableSpec], resolved: String, canSend: Bool, missing: [Snippet.VariableSpec], target: ScriptTarget?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PrimaryButton(title: session.run ? "Run" : "Insert", enabled: canSend, tint: Pal.tint) {
                    guard let t = target else { return }
                    let ok = model.sendScript(resolved, run: session.run, clearFirst: session.clearFirst, tabId: t.id)
                    session.remember(specs: specs)
                    session.statusOK = ok
                    session.status = ok ? String(localized: "Sent to \(t.title)") : String(localized: "Couldn't send — the terminal isn't ready.")
                }
                SecondaryButton(title: "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resolved, forType: .string)
                    session.remember(specs: specs)
                    session.statusOK = true; session.status = String(localized: "Copied")
                }
                .disabled(!missing.isEmpty)
                if let t = target {
                    Button { model.activeTabId = t.id } label: { Label(String(localized: "Show Terminal"), lucideSymbol: "arrow.up.right.square").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(Pal.subtext).pointerCursor()
                }
                Spacer()
            }
            if !missing.isEmpty {
                Text("Fill in: \(missing.map(\.name).joined(separator: ", "))").font(.system(size: 11.5)).foregroundStyle(Pal.yellow)
            } else if target == nil {
                Text("Choose a terminal to run in.").font(.system(size: 11.5)).foregroundStyle(Pal.yellow)
            }
            if let s = session.status { Text(verbatim: s).font(.system(size: 11.5)).foregroundStyle(session.statusOK ? Pal.green : Pal.red) }
        }
    }
}

/// Terminal tab available as a script target.
struct ScriptTarget: Identifiable, Hashable {
    let id: Int
    let title: String
}
