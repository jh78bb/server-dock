import SwiftUI

/// Form to add/edit an RDP (Windows Remote Desktop) host.
/// Separate from SSH AddHostView, with focused address/account/resolution/security fields.
struct AddRDPHostView: View {
    @ObservedObject var model: AppModel
    var editing: Host? = nil
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var group = ""
    @State private var address = ""
    @State private var port = "5900"
    @State private var user = "Administrator"
    @State private var password = ""
    @State private var domain = ""
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var colorDepth = 32
    @State private var security: RDPSecurity = .auto
    @State private var notes = ""
    @State private var colorHex = HostPalette.presets[0]
    @State private var protocolType: RemoteDesktopProtocol = .vnc
    @State private var didLoad = false

    private var isEditing: Bool { editing != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var resolvedGroup: String {
        let g = group.trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? String(localized: "Ungrouped") : g
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    formIntro
                    formSectionLabel("Host")
                    HStack(alignment: .top, spacing: 12) {
                        field(String(localized: "Name"), "My Remote Desktop", $name)
                        groupSelector.frame(width: 190)   // Group appears right of the name.
                    }
                    labeled(String(localized: "Color"), hint: String(localized: "Shown on tabs, terminals and the sidebar to tell servers apart")) {
                        HostColorPicker(hex: $colorHex)
                    }
                    labeled(String(localized: "Protocol")) {
                        SegmentedControl(options: RemoteDesktopProtocol.allCases.map { (value: $0, verbatim: $0.label) }, selection: $protocolType)
                            .frame(width: 190)
                    }
                    formSectionLabel(protocolType == .rdp ? "RDP Connection" : "VNC Connection")
                    HStack(spacing: 12) {
                        field(String(localized: "Address"), "192.168.1.10 or host.example.com", $address)
                        field(String(localized: "Port"), protocolType == .rdp ? "3389" : "5900", $port).frame(width: 90)
                    }
                    if protocolType == .vnc {
                        labeled(String(localized: "Username"), optional: true,
                                hint: String(localized: "macOS Screen Sharing needs your Mac account name. Leave empty for servers that only ask for a password.")) {
                            ThemedTextField(placeholder: "e.g. hoon", text: $user)
                        }
                        labeled(String(localized: "Password"), optional: true) {
                            ThemedSecureField(placeholder: "(VNC password, saved to the system Keychain)", text: $password)
                        }
                        Text("VNC password authentication is limited to 8 characters on many servers.")
                            .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    } else {
                        field(String(localized: "Login User"), "Administrator", $user)
                        labeled(String(localized: "Password"), optional: true) {
                            ThemedSecureField(placeholder: "(Optional, saved to the system Keychain)", text: $password)
                        }
                        labeled(String(localized: "Domain"), optional: true) {
                            ThemedTextField(placeholder: "WORKGROUP / Domain", text: $domain)
                        }
                        HStack(alignment: .bottom, spacing: 12) {
                            field(String(localized: "Width"), "1920", $width).frame(width: 100)
                            field(String(localized: "Height"), "1080", $height).frame(width: 100)
                            labeled(String(localized: "Color Depth")) {
                                ThemedDropdown(
                                    options: [(value: 16, label: "16-bit"), (value: 24, label: "24-bit"), (value: 32, label: "32-bit")],
                                    selection: $colorDepth
                                )
                                .frame(width: 110)
                            }
                        }
                        labeled(String(localized: "Security Level"), hint: String(localized: "Usually \"Auto\". Windows enables NLA by default.")) {
                            ThemedDropdown(
                                options: RDPSecurity.allCases.map { (value: $0, verbatim: $0.label) },
                                selection: $security
                            )
                            .frame(width: 240)
                        }
                    }
                    labeled(String(localized: "Host Notes")) {
                        ThemedTextEditor(placeholder: "Notes…", text: $notes)
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Pal.fill(0.06))
            footer
        }
        .frame(width: 600, height: 620)
        .background(Pal.solidBase)
        .background(NoInitialFocus())   // Do not focus the Name field automatically on open.
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: protocolType) { _, newValue in
            if (newValue == .vnc && port == "3389") || (newValue == .rdp && port == "5900") {
                port = newValue == .vnc ? "5900" : "3389"
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let editing {
                load(from: editing)
            } else {
                colorHex = HostPalette.autoAssign(existing: model.hosts)
            }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Text(isEditing ? "Edit Remote Desktop Host" : "New Remote Desktop Host")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
            Spacer()
            Button { dismiss() } label: {
                Image(lucideSymbol: "xmark")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: isEditing ? "Save" : "Add", enabled: canSave) { save() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var formIntro: some View {
        HStack(spacing: 11) {
            Image(lucideSymbol: "desktopcomputer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Pal.mauve)
                .frame(width: 36, height: 36)
                .background(Pal.mauve.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(protocolType == .vnc ? "VNC Remote Desktop" : "Windows Remote Desktop")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.textBright)
                Text(protocolType == .vnc ? "Connect to a VNC server." : "Set up the host and display preferences.")
                    .font(.system(size: 11))
                    .foregroundStyle(Pal.subtext)
            }
            Spacer()
        }
        .padding(.bottom, 3)
    }

    private func formSectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Pal.overlay)
            .padding(.top, 3)
    }

    // MARK: - Persistence

    private func save() {
        let rdp = buildRDP()
        let n = name.trimmingCharacters(in: .whitespaces)
        let notesT = notes.trimmingCharacters(in: .whitespaces)
        if let editing {
            model.updateRDPHost(id: editing.id, name: n, group: resolvedGroup, notes: notesT, rdp: rdp, colorHex: colorHex)
        } else {
            model.addRDPHost(name: n, group: resolvedGroup, notes: notesT, rdp: rdp, colorHex: colorHex)
        }
        dismiss()
    }

    private func buildRDP() -> RDPConnection {
        let u = user.trimmingCharacters(in: .whitespaces)
        return RDPConnection(
            protocolType: protocolType,
            user: u.isEmpty ? (protocolType == .vnc ? "" : "Administrator") : u,
            host: address.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? (protocolType == .vnc ? 5900 : 3389),
            password: password,
            domain: domain.trimmingCharacters(in: .whitespaces),
            width: Int(width) ?? 1920,
            height: Int(height) ?? 1080,
            colorDepth: colorDepth,
            security: security
        )
    }

    private func load(from host: Host) {
        name = host.name
        group = host.group
        notes = host.notes
        colorHex = host.colorHex ?? HostPalette.hex(from: host.accent)
        guard let r = host.rdp else { return }
        protocolType = r.protocolType
        address = r.host
        port = String(r.port)
        user = (r.protocolType == .vnc && r.user == "Administrator") ? "" : r.user   // Administrator was a VNC default, not user-supplied input.
        password = r.password
        domain = r.domain
        width = String(r.width)
        height = String(r.height)
        colorDepth = r.colorDepth
        security = r.security
    }

    // MARK: - Components

    private func field(_ label: String, _ placeholder: LocalizedStringKey, _ text: Binding<String>) -> some View {
        labeled(label) { ThemedTextField(placeholder: placeholder, text: text) }
    }

    private func labeled<C: View>(_ label: String, optional: Bool = false, hint: String? = nil, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                if optional { Text("Optional").font(.system(size: 10)).foregroundStyle(Pal.overlay) }
            }
            control()
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Pal.overlay) }
        }
    }

    private var groupSelector: some View {
        labeled(String(localized: "Group")) {
            SearchableSelect(options: model.groupNames, text: $group, placeholder: String(localized: "Search or Create Group…"))
        }
    }
}
