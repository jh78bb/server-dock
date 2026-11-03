import AppKit
import SwiftUI

struct AddHostView: View {
    @ObservedObject var model: AppModel
    var editing: Host? = nil
    @StateObject private var draft = HostDraft()
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var section: HostFormSection = .basic
    @State private var showTest = false
    @State private var didLoad = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            HStack(spacing: 0) {
                navSidebar
                Divider().overlay(Pal.fill(0.06))
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().overlay(Pal.fill(0.06))
            footer
        }
        .frame(width: 720, height: 600)
        .background(Pal.solidBase)
        .background(NoInitialFocus())   // Do not focus Name automatically on open.
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let editing {
                draft.load(from: editing)
            } else {
                draft.colorHex = HostPalette.autoAssign(existing: model.hosts)
            }
        }
        .sheet(isPresented: $showTest) {
            TestConnectionView(draft: draft, model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(lucideSymbol: "server.rack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Pal.mauve)
                .frame(width: 38, height: 38)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "Edit Host" : "New Host")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Pal.textBright)
                Text(isEditing ? "Update connection and host details" : "Add a server to your host list")
                    .font(.system(size: 11))
                    .foregroundStyle(Pal.subtext)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(lucideSymbol: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    // MARK: - Left navigation

    private var navSidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("HOST SETUP")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Pal.overlay)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            ForEach(HostFormSection.allCases, id: \.self) { s in
                let selected = section == s
                Button {
                    section = s
                } label: {
                    HStack(spacing: 9) {
                        Image(lucideSymbol: s.icon)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Pal.mauve : Pal.subtext)
                            .frame(width: 20)
                        Text(s.label)
                            .font(.system(size: 12, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Pal.text : Pal.subtext)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(
                        selected ? Pal.mauve.opacity(0.12) : Pal.fill(0.025),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? Pal.mauve.opacity(0.2) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 166)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showTest = true
            } label: {
                HStack(spacing: 6) {
                    Image(lucideSymbol: "bolt.horizontal.circle")
                        .font(.system(size: 13))
                    Text("Test Connection").font(.system(size: 13))
                }
                .foregroundStyle(Pal.mauve)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.mauve.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(draft.canSave)
            .disabled(!draft.canSave)
            .opacity(draft.canSave ? 1 : 0.5)

            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: isEditing ? "Save" : "Add", enabled: draft.canSave) { save() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() {
        if let editing {
            model.updateHost(id: editing.id, from: draft)
        } else {
            model.addHost(from: draft)
        }
        dismiss()
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select")
        if panel.runModal() == .OK, let url = panel.url { draft.localStartDir = url.path }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // ~/.ssh is hidden; show hidden files so users can select keys.
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.prompt = String(localized: "Select")
        if panel.runModal() == .OK, let url = panel.url {
            if AppEnv.isMAS {
                // The sandbox cannot retain arbitrary external paths; import the selected key into the library and use keyId.
                if let key = model.importKey(from: url) { draft.keyId = key.id; draft.keyPath = "" }
            } else {
                draft.keyPath = url.path
            }
        }
    }

    /// Key-source menu: a manually selected file plus each library key.
    private var agentOptions: [(value: String, label: String)] {
        var opts = SSHAgentCatalog.detect().map { a -> (value: String, label: String) in
            (a.socket, a.installed ? a.name : a.name + " (" + String(localized: "not detected") + ")")
        }
        // Retain/display custom agent sockets absent from the detected list.
        if !opts.contains(where: { $0.value == draft.agentSocket }) {
            opts.append((draft.agentSocket, draft.agentSocket))
        }
        return opts
    }

    private var keySourceOptions: [(value: String, label: String)] {
        [(value: "", label: String(localized: "Choose File Manually…"))]
            + model.sshKeys.map { (value: $0.id, label: "\($0.name)（\($0.type.label)）") }
    }

    // MARK: - Section content

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .basic: basicSection
        case .connection: connectionSection
        case .initial: initialSection
        case .proxy: proxySection
        case .advanced: advancedSection
        }
    }

    private var osSSHMode: Bool { !AppEnv.isMAS && !draft.useBuiltinSSH }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "General"))
            groupSelector
            field(String(localized: "Name"), placeholder: "My Server", text: $draft.name)
            if !AppEnv.isMAS {
                labeled(String(localized: "Connection Type")) {
                    ThemedDropdown(
                        options: [(value: false, verbatim: String(localized: "OS SSH (runs the ssh command)")),
                                  (value: true, verbatim: String(localized: "Built-in SSH"))],
                        selection: $draft.useBuiltinSSH
                    )
                    .frame(width: 260)
                }
            }
            labeled(String(localized: "Color"), hint: String(localized: "Shown on tabs, terminals and the sidebar to tell servers apart")) {
                HostColorPicker(hex: $draft.colorHex)
            }
            if osSSHMode {
                field(String(localized: "SSH Command"), placeholder: "ssh hoon@192.168.0.237", text: $draft.sshCommand)
                hintBox([
                    String(localized: "The terminal runs this command as-is, like iTerm, so ~/.ssh/config (ProxyJump, Port, IdentityFile…) applies. A Host alias works too, e.g. `ssh myserver`."),
                    String(localized: "File browser, monitoring and port forwarding read the host, user, port, key and jump host from this command (via `ssh -G`)."),
                ])
                labeled(String(localized: "Local Start Directory"), optional: true) {
                    HStack(spacing: 8) {
                        ThemedTextField(placeholder: "~ (Home directory)", text: $draft.localStartDir)
                        SecondaryButton(title: "Choose…") { chooseLocalDirectory() }
                    }
                }
                labeled(String(localized: "Password / Key Passphrase"), optional: true) {
                    ThemedSecureField(placeholder: "(Optional — typed automatically at the prompt)", text: $draft.password)
                }
            } else {
            HStack(spacing: 12) {
                field(String(localized: "Address"), placeholder: "192.168.1.1 or example.com", text: $draft.address)
                field(String(localized: "Port"), placeholder: "22", text: $draft.port).frame(width: 90)
            }
            labeled(String(localized: "Authentication Method")) {
                ThemedDropdown(
                    options: AuthMethod.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $draft.authMethod
                )
                .frame(width: 200)
            }
            field(String(localized: "Login User"), placeholder: "root", text: $draft.user)
            if draft.authMethod == .key {
                labeled(String(localized: "Key Source")) {
                    ThemedDropdown(options: keySourceOptions.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.keyId)
                }
                if draft.keyId.isEmpty {
                    labeled(String(localized: "Private Key File")) {
                        if AppEnv.isMAS {
                            // Sandbox builds cannot read manually entered external paths; import selected files into the key library.
                            SecondaryButton(title: "Choose a file to import into the key store…") { chooseKeyFile() }
                        } else {
                            HStack(spacing: 8) {
                                ThemedTextField(placeholder: "~/.ssh/id_ed25519", text: $draft.keyPath)
                                SecondaryButton(title: "Choose…") { chooseKeyFile() }
                            }
                        }
                    }
                }
                labeled(String(localized: "Private Key Passphrase"), optional: true) {
                    ThemedSecureField(placeholder: "(Fill in if the private key has a passphrase)", text: $draft.password)
                }
            } else if draft.authMethod == .agent {
                labeled(String(localized: "SSH Agent")) {
                    ThemedDropdown(options: agentOptions.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.agentSocket)
                }
                Text("The private key stays in the agent (1Password, Secretive, ssh-agent) and never passes through this app; the agent may ask you to approve each use.")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.authMethod == .password {
                labeled(String(localized: "Password"), optional: true) {
                    ThemedSecureField(placeholder: "(Optional)", text: $draft.password)
                }
            } else {
                // Ask every time: store no credentials and prompt for this connection's password.
                Text("Prompt for the password on each connection; no credentials are saved.")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            labeled(String(localized: "Host Notes")) {
                ThemedTextEditor(placeholder: "Notes…", text: $draft.notes)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "Connection Settings"))
            field(String(localized: "Timeout (ms)"), placeholder: "10000", text: $draft.timeout)
            field(String(localized: "Heartbeat Interval (ms)"), placeholder: "5000", text: $draft.heartbeat)
        }
    }

    private var initialSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "Initial Options"))
            field(String(localized: "Default Path"), placeholder: "~", text: $draft.defaultPath)
            labeled(String(localized: "Initial Command")) {
                ThemedTextEditor(placeholder: "#!/bin/bash", text: $draft.initialCommand)
            }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "Proxy Settings"))
            hintBox([
                String(localized: "When enabled, traffic is relayed through the proxy."),
                String(localized: "Supports SOCKS4/SOCKS5 proxy, e.g. socks5://127.0.0.1:10808 (with auth: socks5://user:pass@host:port)"),
                String(localized: "Supports HTTP proxy, e.g. http://127.0.0.1:10809 (with auth: http://user:pass@host:port)"),
                String(localized: "Supports HTTPS proxy, e.g. https://127.0.0.1:10809 (with auth: https://user:pass@host:port)"),
                String(localized: "If this is left empty and “Use System Proxy” is enabled in Settings, the system proxy will be used automatically."),
            ])
            labeled(String(localized: "Jump Host")) {
                ThemedTextField(placeholder: "user@bastion.example.com:22", text: $draft.jumpHost)
            }
            hintBox([
                String(localized: "Connects through a bastion (ssh -J / ProxyJump). Separate multiple hops with commas. Overrides the proxy below."),
            ])
            toggleRow(String(localized: "No Proxy"), isOn: $draft.disableProxy)
            labeled(String(localized: "Proxy Settings")) {
                ThemedTextField(placeholder: "socks5://127.0.0.1:10808", text: $draft.proxyURL)
            }
            .opacity(draft.disableProxy ? 0.4 : 1)
            .disabled(draft.disableProxy)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "Advanced Settings"))
            labeled(String(localized: "Terminal Encoding"), hint: String(localized: "Forwarded to the server as LC_ALL; final display of non-UTF-8 output is limited by terminal rendering")) {
                ThemedDropdown(options: SSHOptions.encodings.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.encoding)
                    .frame(width: 240)
            }
            labeled(String(localized: "Host Key Algorithms"), hint: String(localized: "Usually left empty (let SSH negotiate automatically)")) {
                ThemedDropdown(options: SSHOptions.hostKeyAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.hostKeyAlgos)
                    .frame(width: 280)
            }
            labeled(String(localized: "Cipher Algorithm"), hint: String(localized: "Usually left empty (let SSH negotiate automatically)")) {
                ThemedDropdown(options: SSHOptions.ciphers.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.ciphers)
                    .frame(width: 280)
            }
            labeled(String(localized: "Key Exchange Algorithm"), hint: String(localized: "Usually left empty (let SSH negotiate automatically)")) {
                ThemedDropdown(options: SSHOptions.kexAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.kexAlgos)
                    .frame(width: 320)
            }
        }
    }

    // MARK: - Components

    private func sectionTitle(_ t: String) -> some View {
        HStack(spacing: 11) {
            Image(lucideSymbol: section.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Pal.mauve)
                .frame(width: 34, height: 34)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(t)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Pal.textBright)
                Text(sectionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Pal.subtext)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 3)
    }

    private var sectionSummary: String {
        switch section {
        case .basic: return String(localized: "Set the server identity and sign-in method.")
        case .connection: return String(localized: "Tune connection timing for this host.")
        case .initial: return String(localized: "Choose what opens after connecting.")
        case .proxy: return String(localized: "Route this connection through another server or proxy.")
        case .advanced: return String(localized: "Configure terminal encoding and SSH algorithms.")
        }
    }

    private func field(_ label: String, placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        labeled(label) { ThemedTextField(placeholder: placeholder, text: text) }
    }

    private func labeled<C: View>(_ label: String, optional: Bool = false, hint: String? = nil, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                if optional {
                    Text("Optional").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
            }
            control()
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            ThemedToggle(isOn: isOn)
        }
    }

    private func hintBox(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    Text(line).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var groupSelector: some View {
        labeled(String(localized: "Server Group")) {
            SearchableSelect(options: model.groupNames, text: $draft.group, placeholder: String(localized: "Search or Create Group…"))
        }
    }
}
