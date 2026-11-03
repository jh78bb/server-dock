import SwiftUI
import AppKit

/// Firewall-open request with host and optional prefilled port.
struct FirewallRequest: Identifiable {
    let id = UUID()
    let host: Host
    var port: Int? = nil
    var proto: String = "tcp"
}

/// View/add/edit/delete ufw/firewalld rules; nftables/iptables remain read-only.
/// Preview/confirm every mutation, separately warning for potential SSH lockout.
struct FirewallView: View {
    @ObservedObject var model: AppModel
    let request: FirewallRequest
    @StateObject private var session: FirewallSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    private struct Pending {
        let title: String
        let commands: [String]
        let risk: String?
        let confirmLabel: String
        let run: () -> Void
    }

    @State private var selection = Set<String>()
    @State private var pending: Pending?
    @State private var editor: EditorTarget?
    @State private var showRaw = false
    @State private var didPrefill = false

    private struct EditorTarget: Identifiable { let id = UUID(); let rule: FWRule? }

    init(model: AppModel, request: FirewallRequest) {
        self.model = model
        self.request = request
        _session = StateObject(wrappedValue: FirewallSession(host: request.host))
    }

    private var host: Host { request.host }
    private var st: FirewallState { session.state }
    private var selectedRules: [FWRule] { st.rules.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            if let n = session.notice { banner(n, color: Pal.red, symbol: "exclamationmark.triangle.fill") }
            if let i = session.info { banner(i, color: Pal.green, symbol: "checkmark.circle.fill") }
            content
        }
        .frame(width: 900, height: 640)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { session.refresh() }
        .onChange(of: session.phase) { p in
            if p == .ready, !didPrefill, let port = request.port, st.backend.canEdit, !st.needsRoot { didPrefill = true; editor = EditorTarget(rule: nil) }
        }
        .sheet(item: $editor) { target in
            FirewallRuleEditor(backend: st.backend, zones: st.zones, existing: target.rule, prefillPort: request.port, prefillProto: request.proto,
                               ruleCount: st.rules.filter { !$0.isV6 }.count, sshPort: session.sshPort) { payload in
                editor = nil
                submit(payload, editing: target.rule)
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let p = pending {
                Button(p.confirmLabel, role: p.risk != nil ? .destructive : nil) { let run = p.run; pending = nil; run() }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            if let p = pending {
                Text(([p.risk].compactMap { $0 } + [String(localized: "Commands that will run:")] + p.commands.map { "$ " + $0 }).joined(separator: "\n\n"))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: "flame").font(.system(size: 14)).foregroundStyle(host.accent)
            Text("Firewall").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
            Text(host.name).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            if session.phase == .ready, st.backend != .none {
                Text(st.backend.title).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Pal.subtext)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Pal.fill(0.08), in: Capsule())
                Text(st.active ? String(localized: "Active") : String(localized: "Inactive"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(st.active ? Pal.green : Pal.yellow)
                    .padding(.horizontal, 7).padding(.vertical, 2).background((st.active ? Pal.green : Pal.yellow).opacity(0.12), in: Capsule())
                if !st.defaults.isEmpty {
                    Text(verbatim: st.defaults).font(.system(size: 10.5)).foregroundStyle(Pal.overlay).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            if session.busy { ProgressView().controlSize(.small) }
            Toggle("sudo", isOn: $session.useSudo).toggleStyle(.checkbox).font(.system(size: 11))
                .help(String(localized: "Read and change the firewall with passwordless sudo (sudo -n)"))
                .onChange(of: session.useSudo) { _ in session.refresh() }
            iconButton("arrow.clockwise", String(localized: "Refresh")) { session.refresh() }
            Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }
                .buttonStyle(.plain).pointerCursor()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func banner(_ text: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(lucideSymbol: symbol).foregroundStyle(color)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            Button { session.notice = nil; session.info = nil } label: { Image(lucideSymbol: "xmark").font(.system(size: 10)).foregroundStyle(Pal.overlay) }
                .buttonStyle(.plain).pointerCursor()
        }
        .padding(10).background(color.opacity(0.10))
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            VStack(spacing: 10) { ProgressView(); Text("Reading firewall…").font(.system(size: 12)).foregroundStyle(Pal.subtext) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notLinux:
            message("flame", String(localized: "Firewall management is for Linux servers"), String(localized: "This server doesn't look like Linux (macOS uses its own application firewall and pf)."))
        case .failed(let m):
            message("exclamationmark.triangle", String(localized: "Couldn't read the firewall"), m)
        case .ready:
            if st.backend == .none {
                message("flame", String(localized: "No firewall found"), String(localized: "ufw, firewalld, nftables and iptables aren't installed for this account. Install one (for example: sudo apt install ufw) or check the sudo option."))
            } else if st.needsRoot {
                message("lock", String(localized: "Root is needed to read the firewall"), String(localized: "Turn on the sudo option above if this account has passwordless sudo (sudo -n)."))
            } else if st.backend.canEdit {
                editable
            } else {
                readOnly
            }
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(lucideSymbol: symbol).font(.system(size: 30)).foregroundStyle(Pal.overlay)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Pal.subtext).multilineTextAlignment(.center).frame(maxWidth: 480)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readOnly: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read-only: \(st.backend.title) rules are chains and tables that depend on their order, so they can't be safely edited from a list. Use ufw or firewalld for managed rules, or the terminal.")
                .font(.system(size: 11.5)).foregroundStyle(Pal.subtext).padding(.horizontal, 16).padding(.top, 10)
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: st.rawText.isEmpty ? "—" : st.rawText).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Pal.fill(0.03))
        }
    }

    // MARK: Editable ufw / firewalld

    private var editable: some View {
        VStack(spacing: 0) {
            toolbar
            Table(st.rules, selection: $selection) {
                TableColumn(st.backend == .ufw ? "#" : String(localized: "Zone")) { r in
                    Text(verbatim: r.number.map(String.init) ?? r.zone ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                }.width(min: 44, ideal: 70, max: 110)
                TableColumn(String(localized: "Rule")) { r in
                    HStack(spacing: 6) {
                        Text(verbatim: r.target).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        if r.isV6 { Text("v6").font(.system(size: 9, weight: .semibold)).foregroundStyle(Pal.overlay).padding(.horizontal, 4).background(Pal.fill(0.08), in: Capsule()) }
                        if st.backend == .firewalld { Text(verbatim: r.kind).font(.system(size: 9)).foregroundStyle(Pal.overlay) }
                    }
                }.width(min: 140, ideal: 220)
                TableColumn(String(localized: "Action")) { r in
                    let deny = r.action.uppercased().hasPrefix("DENY") || r.action.uppercased().hasPrefix("REJECT") || r.action == "drop" || r.action == "reject"
                    Text(verbatim: r.action.uppercased()).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(deny ? Pal.red : Pal.green)
                }.width(min: 80, ideal: 100)
                TableColumn(String(localized: "From")) { r in
                    Text(verbatim: r.source.isEmpty ? String(localized: "Anywhere") : r.source).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext).lineLimit(1)
                }.width(min: 100, ideal: 160)
                TableColumn(String(localized: "Comment")) { r in Text(verbatim: r.comment).foregroundStyle(Pal.overlay).lineLimit(1) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let rs = st.rules.filter { ids.contains($0.id) }
                if !rs.isEmpty { rowMenu(rs) }
            } primaryAction: { ids in
                if ids.count == 1, let r = st.rules.first(where: { $0.id == ids.first }), r.editable { editor = EditorTarget(rule: r) }
            }
            .overlay {
                if st.rules.isEmpty {
                    Text(st.active ? String(localized: "No rules yet") : String(localized: "The firewall is inactive, so no rules are listed."))
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false)
                }
            }
            if !st.rawText.isEmpty {
                DisclosureGroup(isExpanded: $showRaw) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: st.rawText).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.subtext).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.frame(height: 150).background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 6))
                } label: { Text("Underlying nftables / iptables rules (read-only)").font(.system(size: 11)).foregroundStyle(Pal.subtext) }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
            Divider().overlay(Pal.fill(0.06))
            Text(st.backend == .firewalld
                 ? "Changes are saved permanently and the firewall is reloaded. Rules added only at runtime (without --permanent) are lost by a reload."
                 : "Rules are evaluated top to bottom: the first match wins. New rules go to the end unless you pick a position.")
                .font(.system(size: 10.5)).foregroundStyle(Pal.overlay).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var toolbar: some View {
        let sel = selectedRules
        return HStack(spacing: 8) {
            Button { editor = EditorTarget(rule: nil) } label: {
                Label("Add Rule", lucideSymbol: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.tint)
                    .padding(.horizontal, 11).padding(.vertical, 6).background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
            }.buttonStyle(.plain).pointerCursor()
            iconButton("pencil", String(localized: "Edit"), disabled: !(sel.count == 1 && sel[0].editable)) { if let r = sel.first { editor = EditorTarget(rule: r) } }
            iconButton("trash", String(localized: "Delete"), disabled: sel.isEmpty) { confirmDelete(sel) }
            Spacer()
            if st.backend == .ufw {
                Menu {
                    Button("Default: deny incoming") { confirmDefault("deny") }
                    Button("Default: allow incoming") { confirmDefault("allow") }
                } label: { Label("Default policy", lucideSymbol: "shield").font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize()
                if st.active {
                    Button { confirmToggle(false) } label: { pill(String(localized: "Disable Firewall"), Pal.red) }.buttonStyle(.plain).pointerCursor()
                } else {
                    Button { confirmToggle(true, allowSSH: true) } label: { pill(String(localized: "Allow SSH and Enable"), Pal.green) }.buttonStyle(.plain).pointerCursor()
                    Button { confirmToggle(true) } label: { pill(String(localized: "Enable"), Pal.subtext) }.buttonStyle(.plain).pointerCursor()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11.5, weight: .medium)).foregroundStyle(c)
            .padding(.horizontal, 10).padding(.vertical, 5).background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowMenu(_ rs: [FWRule]) -> some View {
        if rs.count == 1, let r = rs.first, r.editable { Button("Edit…") { editor = EditorTarget(rule: r) } }
        Button("Copy Rule") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rs.map(\.raw).joined(separator: "\n"), forType: .string) }
        Divider()
        Button("Delete", role: .destructive) { confirmDelete(rs) }
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12)).foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }

    // MARK: Confirmed actions

    private func confirmDelete(_ rules: [FWRule]) {
        guard !rules.isEmpty else { return }
        let cmds: [String] = st.backend == .ufw
            ? rules.sorted { ($0.number ?? 0) > ($1.number ?? 0) }.compactMap { $0.number.map { "ufw --force delete \($0)" } }
            : rules.compactMap { $0.fwd.map { FirewallScanner.firewalldRemove($0) } }
        let title = rules.count == 1 ? String(localized: "Delete this rule?") : String(localized: "Delete \(rules.count) rules?")
        pending = Pending(title: title, commands: cmds, risk: session.riskOfDeleting(rules), confirmLabel: String(localized: "Delete")) {
            Task { await session.delete(rules); selection = [] }
        }
    }

    private func confirmToggle(_ on: Bool, allowSSH: Bool = false) {
        var cmds: [String] = []
        if on && allowSSH { cmds.append("ufw allow \(session.sshPort)/tcp comment 'SSH'") }
        cmds.append(on ? "ufw --force enable" : "ufw disable")
        let risk = on && !allowSSH ? session.riskOfEnabling() : nil
        pending = Pending(title: on ? String(localized: "Enable the firewall?") : String(localized: "Disable the firewall?"), commands: cmds, risk: risk,
                          confirmLabel: on ? String(localized: "Enable") : String(localized: "Disable")) {
            Task { await session.setUfwEnabled(on, allowSSHFirst: allowSSH) }
        }
    }

    private func confirmDefault(_ policy: String) {
        var risk: String?
        if policy == "deny", st.active, !st.rules.contains(where: { FirewallScanner.allowsSSH($0, sshPort: session.sshPort) }) {
            risk = String(localized: "No rule allows SSH (port \(session.sshPort)). Denying incoming traffic by default would refuse new SSH connections.")
        }
        pending = Pending(title: String(localized: "Change the default incoming policy?"), commands: ["ufw default \(policy) incoming"], risk: risk,
                          confirmLabel: String(localized: "Change")) { Task { await session.setUfwDefault(incoming: policy) } }
    }

    private func submit(_ payload: FirewallRuleEditor.Payload, editing rule: FWRule?) {
        switch payload {
        case .ufw(let spec, let insertAt):
            var cmds: [String]
            var risk = session.riskOfAdding(spec)
            if let rule, rule.ufw != nil, let n = rule.number {
                cmds = ["ufw --force delete \(n)", FirewallScanner.ufwAdd(spec, insertAt: n)]
                // Warn if editing removes SSH access and the original was its sole allowance.
                let updated = FWRule(id: "", number: nil, zone: nil, kind: "rule", target: "", action: "", source: "", comment: "", isV6: false,
                                     raw: "", editable: true, ufw: spec, fwd: nil)
                if !FirewallScanner.allowsSSH(updated, sshPort: session.sshPort) { risk = risk ?? session.riskOfDeleting([rule]) }
                pending = Pending(title: String(localized: "Save changes to this rule?"), commands: cmds, risk: risk, confirmLabel: String(localized: "Save")) {
                    Task { await session.editUfw(rule, to: spec) }
                }
            } else {
                cmds = [FirewallScanner.ufwAdd(spec, insertAt: insertAt)]
                pending = Pending(title: String(localized: "Add this rule?"), commands: cmds, risk: risk, confirmLabel: String(localized: "Add")) {
                    Task { await session.addUfw(spec, insertAt: insertAt) }
                }
            }
        case .firewalld(let spec):
            if let rule, let old = rule.fwd {
                pending = Pending(title: String(localized: "Save changes to this rule?"), commands: [FirewallScanner.firewalldRemove(old), FirewallScanner.firewalldAdd(spec)],
                                  risk: session.riskOfDeleting([rule]), confirmLabel: String(localized: "Save")) { Task { await session.editFirewalld(rule, to: spec) } }
            } else {
                pending = Pending(title: String(localized: "Add this rule?"), commands: [FirewallScanner.firewalldAdd(spec)], risk: nil, confirmLabel: String(localized: "Add")) {
                    Task { await session.addFirewalld(spec) }
                }
            }
        }
    }
}

/// Rule editor chooses backend-specific ufw/firewalld fields and previews the command.
struct FirewallRuleEditor: View {
    enum Payload { case ufw(UfwSpec, insertAt: Int?), firewalld(FirewalldSpec) }

    let backend: FirewallBackend
    let zones: [String]
    let existing: FWRule?
    let prefillPort: Int?
    let prefillProto: String
    let ruleCount: Int
    let sshPort: Int
    let onSubmit: (Payload) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var u = UfwSpec()
    @State private var f = FirewalldSpec()
    @State private var position = ""
    @State private var loaded = false

    private var problem: String? {
        if backend == .ufw {
            if let p = FirewallScanner.ufwProblem(u) { return p }
            if !position.isEmpty, let n = Int(position), n >= 1, n <= max(1, ruleCount + 1) { return nil }
            return position.isEmpty ? nil : String(localized: "Position must be between 1 and \(ruleCount + 1).")
        }
        return FirewallScanner.firewalldProblem(f)
    }

    private var preview: String {
        backend == .ufw ? FirewallScanner.ufwAdd(u, insertAt: Int(position)) : FirewallScanner.firewalldAdd(f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(lucideSymbol: "flame").foregroundStyle(Pal.tint)
                Text(existing == nil ? "Add Firewall Rule" : "Edit Firewall Rule").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }.buttonStyle(.plain).pointerCursor()
            }
            if backend == .ufw { ufwForm } else { firewalldForm }
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: "$").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.overlay)
                Text(verbatim: preview).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Pal.textBright)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Pal.yellow).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                SecondaryButton(title: "Cancel") { dismiss() }
                PrimaryButton(title: existing == nil ? "Review" : "Review Changes", enabled: problem == nil, tint: Pal.tint) {
                    onSubmit(backend == .ufw ? .ufw(u, insertAt: existing == nil ? Int(position) : nil) : .firewalld(f))
                }
            }
        }
        .padding(20).frame(width: 560)
        .background(Pal.solidBase).preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let e = existing {
            if let s = e.ufw { u = s }
            if let s = e.fwd { f = s }
        } else {
            if let p = prefillPort { u.port = String(p); u.proto = prefillProto; f.port = String(p); f.proto = prefillProto }
            f.zone = zones.first ?? ""
        }
        if f.zone.isEmpty { f.zone = zones.first ?? "" }
    }

    private var ufwForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                labeled(String(localized: "Action")) {
                    SegmentedControl(options: [(value: "allow", label: LocalizedStringKey("Allow")), (value: "deny", label: LocalizedStringKey("Deny")),
                                               (value: "reject", label: LocalizedStringKey("Reject")), (value: "limit", label: LocalizedStringKey("Limit"))], selection: $u.action)
                }
                labeled(String(localized: "Direction")) {
                    SegmentedControl(options: [(value: "in", label: LocalizedStringKey("In")), (value: "out", label: LocalizedStringKey("Out"))], selection: $u.direction).frame(width: 110)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                labeled(String(localized: "Port / application")) { textField("22, 80,443, 6000:6007 or OpenSSH", $u.port) }
                labeled(String(localized: "Protocol")) {
                    SegmentedControl(options: [(value: "any", verbatim: String(localized: "Any")), (value: "tcp", verbatim: "TCP"), (value: "udp", verbatim: "UDP")], selection: $u.proto)
                }.frame(width: 190)
            }
            HStack(alignment: .top, spacing: 12) {
                labeled(String(localized: "From (empty = anywhere)")) { textField("e.g. 203.0.113.5 or 10.0.0.0/24", $u.from) }
                labeled(String(localized: "Comment")) { textField("optional", $u.comment) }
            }
            if existing == nil {
                labeled(String(localized: "Position (empty = end of the list)")) { textField("e.g. 1", $position).frame(width: 120) }
            }
            if u.action == "limit" {
                Text("Limit allows connections but denies an address that tries more than 6 in 30 seconds (useful for SSH).").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    private var firewalldForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                labeled(String(localized: "Type")) {
                    SegmentedControl(options: [(value: FirewalldSpec.Kind.port, label: LocalizedStringKey("Port")), (value: .service, label: LocalizedStringKey("Service")),
                                               (value: .rich, label: LocalizedStringKey("Port from a source"))], selection: $f.kind).disabled(existing != nil)
                }
                labeled(String(localized: "Zone")) {
                    Menu(f.zone.isEmpty ? "—" : f.zone) { ForEach(zones, id: \.self) { z in Button(z) { f.zone = z } } }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            switch f.kind {
            case .port, .rich:
                HStack(alignment: .top, spacing: 12) {
                    labeled(String(localized: "Port")) { textField("8080 or 6000-6007", $f.port) }
                    labeled(String(localized: "Protocol")) { SegmentedControl(options: [(value: "tcp", verbatim: "TCP"), (value: "udp", verbatim: "UDP")], selection: $f.proto).frame(width: 130) }
                }
                if f.kind == .rich {
                    HStack(alignment: .top, spacing: 12) {
                        labeled(String(localized: "From (empty = anywhere)")) { textField("e.g. 203.0.113.5 or 10.0.0.0/24", $f.source) }
                        labeled(String(localized: "Action")) {
                            SegmentedControl(options: [(value: "accept", label: LocalizedStringKey("Allow")), (value: "reject", label: LocalizedStringKey("Reject")),
                                                       (value: "drop", label: LocalizedStringKey("Drop"))], selection: $f.action).frame(width: 210)
                        }
                    }
                }
            case .service:
                labeled(String(localized: "Service")) {
                    HStack {
                        textField("e.g. http", $f.service)
                        Menu("Common") { ForEach(["ssh", "http", "https", "mysql", "postgresql", "dns", "smtp", "cockpit"], id: \.self) { s in Button(s) { f.service = s } } }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11)).foregroundStyle(Pal.overlay); content() }
    }

    private func textField(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 7).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}
