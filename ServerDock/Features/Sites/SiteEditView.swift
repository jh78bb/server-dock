import SwiftUI
import AppKit

/// Site form varies SMB/WebDAV/S3 fields and tests connections before saving.
struct SiteEditView: View {
    @ObservedObject var model: AppModel
    var editing: Site? = nil
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var site = Site()
    @State private var secret = ""
    @State private var portText = ""
    @State private var didLoad = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    private var kinds: [Site.Kind] { Site.Kind.allCases.filter { !($0 == .smb && !AppEnv.smbEnabled) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "Add Storage" : "Edit Storage")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labeled(String(localized: "Type")) {
                        SegmentedControl(options: kinds.map { (value: $0, verbatim: $0.label) }, selection: $site.kind)
                        .onChange(of: site.kind) { _ in applyKindDefaults() }
                    }
                    labeled(String(localized: "Name")) { ThemedTextField(placeholder: "e.g. Office NAS", text: $site.name) }
                    kindFields
                    labeled(String(localized: "Group")) {
                        SearchableSelect(options: model.siteGroupNames, text: $site.group,
                                         placeholder: String(localized: "Search or Create Group…"))
                    }
                    if let r = testResult {
                        HStack(alignment: .top, spacing: 6) {
                            Image(lucideSymbol: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.ok ? Pal.green : Pal.red)
                            Text(r.message).font(.system(size: 12)).foregroundStyle(r.ok ? Pal.green : Pal.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Button { runTest() } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test Connection")
                    }
                    .font(.system(size: 13)).foregroundStyle(Pal.text)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().disabled(!site.isValid || testing)
                Spacer()
                SecondaryButton(title: "Cancel") { dismiss() }
                PrimaryButton(title: editing == nil ? "Add" : "Save", enabled: site.isValid) { save() }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 500, height: 560)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear(perform: loadOnce)
    }

    // MARK: Protocol-specific fields

    @ViewBuilder
    private var kindFields: some View {
        switch site.kind {
        case .smb:
            labeled(String(localized: "Server")) { ThemedTextField(placeholder: "e.g. nas.local or 192.168.0.10", text: $site.host) }
            HStack(alignment: .top, spacing: 12) {
                labeled(String(localized: "Share")) { ThemedTextField(placeholder: "e.g. Documents", text: $site.path) }
                labeled(String(localized: "Port")) { portField("445").frame(width: 90) }
            }
            labeled(String(localized: "Username")) { ThemedTextField(placeholder: "Leave empty for guest access", text: $site.username) }
            labeled(String(localized: "Password")) { ThemedSecureField(placeholder: "(Optional, saved to the system Keychain)", text: $secret) }
            hint(String(localized: "Uses the macOS SMB client. The share is mounted privately for this app and unmounted when you close the tab."))
        case .webdav:
            labeled(String(localized: "Server")) { ThemedTextField(placeholder: "e.g. cloud.example.com", text: $site.host) }
            HStack(alignment: .top, spacing: 12) {
                labeled(String(localized: "Base Path")) { ThemedTextField(placeholder: "e.g. /remote.php/dav/files/me", text: $site.path) }
                labeled(String(localized: "Port")) { portField(site.useTLS ? "443" : "80").frame(width: 90) }
            }
            Toggle("Use HTTPS", isOn: $site.useTLS).toggleStyle(.checkbox).font(.system(size: 13))
            labeled(String(localized: "Username")) { ThemedTextField(placeholder: "(Optional)", text: $site.username) }
            labeled(String(localized: "Password")) { ThemedSecureField(placeholder: "(Optional, saved to the system Keychain)", text: $secret) }
            if site.useTLS { insecureToggle }
        case .sftp:
            HStack(alignment: .top, spacing: 12) {
                labeled(String(localized: "Server")) { ThemedTextField(placeholder: "e.g. example.com", text: $site.host) }
                labeled(String(localized: "Port")) { portField("22").frame(width: 90) }
            }
            labeled(String(localized: "Username")) { ThemedTextField(placeholder: "e.g. root", text: $site.username) }
            labeled(site.keyPath.isEmpty ? String(localized: "Password") : String(localized: "Key Passphrase")) {
                ThemedSecureField(placeholder: "(Optional, saved to the system Keychain)", text: $secret)
            }
            labeled(String(localized: "Private Key File")) {
                HStack(spacing: 8) {
                    ThemedTextField(placeholder: "Leave empty to use the password", text: $site.keyPath)
                    Button { chooseKey() } label: {
                        Text("Choose…").font(.system(size: 12)).foregroundStyle(Pal.text)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
            labeled(String(localized: "Start Folder")) { ThemedTextField(placeholder: "Leave empty to start in the home folder", text: $site.path) }
            hint(String(localized: "Uses the built-in SSH engine. The server's fingerprint is confirmed the first time you connect."))
        case .s3:
            labeled(String(localized: "Endpoint")) { ThemedTextField(placeholder: "Leave empty for AWS S3, or e.g. minio.example.com", text: $site.host) }
            HStack(alignment: .top, spacing: 12) {
                labeled(String(localized: "Region")) { ThemedTextField(placeholder: "us-east-1", text: $site.region) }
                labeled(String(localized: "Port")) { portField(site.useTLS ? "443" : "80").frame(width: 90) }
            }
            labeled(String(localized: "Bucket")) { ThemedTextField(placeholder: "Leave empty to list all buckets", text: $site.path) }
            labeled(String(localized: "Access Key ID")) { ThemedTextField(placeholder: "", text: $site.username) }
            labeled(String(localized: "Secret Access Key")) { ThemedSecureField(placeholder: "(Saved to the system Keychain)", text: $secret) }
            Toggle("Use HTTPS", isOn: $site.useTLS).toggleStyle(.checkbox).font(.system(size: 13))
            Toggle("Path-style addressing (MinIO, Ceph, most self-hosted)", isOn: $site.pathStyle).toggleStyle(.checkbox).font(.system(size: 13))
            if site.useTLS { insecureToggle }
        }
    }

    private var insecureToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Allow untrusted certificate", isOn: $site.insecureTLS).toggleStyle(.checkbox).font(.system(size: 13))
            if site.insecureTLS {
                hint(String(localized: "Skips certificate verification for this server only. Use it for self-signed NAS certificates."))
            }
        }
    }

    private func portField(_ placeholder: String) -> some View {
        ThemedTextField(verbatim: placeholder, text: $portText)
            .onChange(of: portText) { v in
                let digits = v.filter(\.isNumber)
                if digits != v { portText = digits }
                site.port = Int(digits) ?? 0
            }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Pal.overlay).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }

    // MARK: Actions

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        if let ed = editing {
            site = ed
            secret = SiteKeychain.secret(ed.id)
            portText = ed.port > 0 ? String(ed.port) : ""
        } else if !kinds.contains(site.kind) {
            site.kind = kinds.first ?? .webdav
        }
    }

    private func applyKindDefaults() {
        testResult = nil
        if site.kind == .s3, site.region.isEmpty { site.region = "us-east-1" }
    }

    private func normalized() -> Site {
        var s = site
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.username = s.username.trimmingCharacters(in: .whitespaces)
        s.group = s.group.trimmingCharacters(in: .whitespaces)
        s.path = s.path.trimmingCharacters(in: .whitespaces)
        s.keyPath = s.keyPath.trimmingCharacters(in: .whitespaces)
        return s
    }

    private func chooseKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        if p.runModal() == .OK, let u = p.url { site.keyPath = u.path }
    }

    private func runTest() {
        let s = normalized(), pw = secret
        testing = true; testResult = nil
        Task {
            if s.kind == .sftp, await !model.verifyFingerprint(host: s.host, port: s.port > 0 ? s.port : 22) {
                testing = false; return
            }
            let backend = SiteBackendFactory.make(s, secret: pw)
            do {
                try await backend.connect()
                let n = try await backend.list("/").count
                testResult = (true, String(localized: "Connected. Found \(n) items at the root."))
            } catch {
                testResult = (false, error.localizedDescription)
            }
            await backend.disconnect()
            testing = false
        }
    }

    private func save() {
        let s = normalized()
        if editing != nil { model.updateSite(s, secret: secret) } else { model.addSite(s, secret: secret) }
        dismiss()
    }
}
