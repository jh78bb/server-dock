import SwiftUI

/// SSH Key Manager directly manages a real on-disk key directory, default ~/.ssh, independently
/// of ServerDock's Keychain-managed connection credentials under the activity-bar key icon.
/// Tabs: Keys for generate/rename/copy/delete/comments/passphrases; Config for Host-block editing and reachability;
/// Known Hosts for viewing/deleting known_hosts entries.
struct SSHKeyManagerView: View {
    @ObservedObject var model: SSHKeyManagerModel
    @ObservedObject private var theme = ThemeManager.shared

    private enum Tab: String, CaseIterable, Identifiable {
        case keys, config, knownHosts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keys: return String(localized: "Keys")
            case .config: return String(localized: "Config")
            case .knownHosts: return String(localized: "Known Hosts")
            }
        }
    }
    @State private var tab: Tab = .keys

    @State private var query = ""
    @State private var showGenerate = false
    @State private var renamingKey: SSHKeyItem?
    @State private var duplicatingKey: SSHKeyItem?
    @State private var passphraseKey: SSHKeyItem?
    @State private var deletingKey: SSHKeyItem?

    private var filteredKeys: [SSHKeyItem] {
        guard !query.isEmpty else { return model.keys }
        let q = query.lowercased()
        return model.keys.filter {
            $0.name.lowercased().contains(q) || $0.comment.lowercased().contains(q) || $0.fingerprint.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Pal.fill(0.06))
            Group {
                switch tab {
                case .keys:
                    HStack(spacing: 0) {
                        sidebar.frame(width: 260)
                        Divider().overlay(Pal.fill(0.06))
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .config:
                    SSHConfigManagerTabView(model: model)
                case .knownHosts:
                    KnownHostsManagerTabView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { model.loadAll() }
        .sheet(isPresented: $showGenerate) {
            SSHKeyGenerateSheet(model: model)
        }
        .sheet(item: $renamingKey) { key in
            SSHKeyRenameSheet(model: model, key: key, title: String(localized: "Rename Key")) { newName in
                model.rename(key, to: newName)
            }
        }
        .sheet(item: $duplicatingKey) { key in
            SSHKeyRenameSheet(model: model, key: key, title: String(localized: "Duplicate Key"),
                              initialName: model.availableName(for: key.name)) { newName in
                model.duplicate(key, to: newName)
            }
        }
        .sheet(item: $passphraseKey) { key in
            SSHKeyPassphraseSheet(model: model, key: key)
        }
        .alert(String(localized: "Delete Key?"), isPresented: Binding(
            get: { deletingKey != nil }, set: { if !$0 { deletingKey = nil } }
        ), presenting: deletingKey) { key in
            Button(String(localized: "Delete"), role: .destructive) { model.delete(key) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { key in
            Text("This permanently deletes \(key.name)\(key.kind == .completePair ? " and its .pub file" : "") from disk. This cannot be undone.")
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    /// Top row combines Keys/Config/Known Hosts navigation, directory/read-only menus, and Generate Key.
    private var topBar: some View {
        HStack(spacing: 12) {
            SegmentedControl(options: Tab.allCases.map { (value: $0, verbatim: $0.title) }, selection: $tab)
                .frame(width: 300)
            Spacer()
            Menu {
                Text(verbatim: model.directoryPath)
                Divider()
                Button(String(localized: "Choose Folder…")) { model.chooseDirectory() }
                if model.directoryPath != "~/.ssh" { Button(String(localized: "Reset to ~/.ssh")) { model.resetToDefaultDirectory() } }
                Divider()
                Toggle(String(localized: "Read-Only Mode"), isOn: $model.isReadOnlyModeEnabled)
            } label: {
                HStack(spacing: 6) {
                    Image(lucideSymbol: model.isReadOnlyModeEnabled ? "lock.fill" : "folder").font(.system(size: 11))
                    Text(verbatim: model.directoryPath).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Image(lucideSymbol: "chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(Pal.subtext).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(String(localized: "Blocks generate/rename/duplicate/delete/comment/passphrase changes") + " — " + String(localized: "Read-Only Mode"))
            if tab == .keys {
                PrimaryButton(title: "Generate New Key", tint: Pal.tint) { showGenerate = true }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                TextField(String(localized: "Search Keys…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.top, 10)

            if model.isLoading && model.keys.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if model.keys.isEmpty {
                emptyState
            } else if filteredKeys.isEmpty {
                Spacer()
                Text("No Matching Keys").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredKeys) { key in row(key) }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(lucideSymbol: "key").font(.system(size: 24)).foregroundStyle(Pal.overlay)
            Text("No keys in this directory").font(.system(size: 12)).foregroundStyle(Pal.subtext)
            Spacer()
        }
    }

    private func row(_ key: SSHKeyItem) -> some View {
        let selected = model.selectedKeyID == key.id
        return Button { model.selectedKeyID = key.id } label: {
            HStack(spacing: 10) {
                Image(lucideSymbol: "key.fill").font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.tint : Pal.overlay).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                    Text("\(key.type) · \(key.kind.title)").font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                }
                Spacer(minLength: 0)
                if key.isPassphraseProtected {
                    Image(lucideSymbol: "lock.fill").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? Pal.tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    @ViewBuilder
    private var detail: some View {
        if let key = model.selectedKey {
            SSHKeyDetailPane(model: model, key: key,
                             onRename: { renamingKey = key }, onDuplicate: { duplicatingKey = key },
                             onPassphrase: { passphraseKey = key }, onDelete: { deletingKey = key })
        } else {
            VStack {
                Spacer()
                Text("Select a key").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SSHKeyDetailPane: View {
    @ObservedObject var model: SSHKeyManagerModel
    let key: SSHKeyItem
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onPassphrase: () -> Void
    let onDelete: () -> Void

    @State private var comment = ""
    @State private var commentDirty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(lucideSymbol: "key.fill").font(.system(size: 18)).foregroundStyle(Pal.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                        Text(verbatim: key.filePath).font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }

                actionsRow

                VStack(alignment: .leading, spacing: 9) {
                    info(String(localized: "Type"), "\(key.type) · \(key.kind.title)")
                    info(String(localized: "Fingerprint"), key.fingerprint)
                    info(String(localized: "Passphrase"), key.isPassphraseProtected ? String(localized: "Protected") : String(localized: "None"))
                    info(String(localized: "Created"), Self.dateFormatter.string(from: key.createdAt))
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.08), lineWidth: 1))

                if key.publicKeyPath != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comment").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        HStack(spacing: 8) {
                            ThemedTextField(placeholder: "user@host", text: $comment)
                                .onChange(of: comment) { _ in commentDirty = true }
                            Button(String(localized: "Save")) {
                                model.updateComment(key, comment: comment); commentDirty = false
                            }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.tint).pointerCursor()
                            .disabled(!commentDirty)
                            .opacity(commentDirty ? 1 : 0.4)
                        }
                    }
                }

                if let pubPath = key.publicKeyPath, let pubText = try? String(contentsOfFile: pubPath, encoding: .utf8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Public Key").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        Text(pubText.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { comment = key.comment == "No comment" ? "" : key.comment; commentDirty = false }
        .onChange(of: key.id) { _ in comment = key.comment == "No comment" ? "" : key.comment; commentDirty = false }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button { model.copyPublicKey(key) } label: {
                Label(String(localized: "Copy Public Key"), lucideSymbol: "doc.on.doc").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Pal.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(Pal.tint)
            }
            .buttonStyle(.plain).pointerCursor().disabled(key.publicKeyPath == nil).opacity(key.publicKeyPath == nil ? 0.4 : 1)
            Menu {
                Button(String(localized: "Copy Fingerprint")) { model.copyFingerprint(key) }
                Button(String(localized: "Copy Private Key")) { model.copyPrivateKey(key) }.disabled(key.privateKeyPath == nil)
                Button(String(localized: "Reveal in Finder")) { model.revealInFinder(key) }
                Divider()
                Button(String(localized: "Rename"), action: onRename)
                Button(String(localized: "Duplicate"), action: onDuplicate)
                Button(key.isPassphraseProtected ? String(localized: "Change Passphrase") : String(localized: "Add Passphrase"), action: onPassphrase)
                    .disabled(key.privateKeyPath == nil)
                Divider()
                Button(String(localized: "Delete"), role: .destructive, action: onDelete)
            } label: {
                Label(String(localized: "More"), lucideSymbol: "ellipsis").font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(Pal.subtext)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
}
