import AppKit
import Foundation

/// SSH Key Manager state is independent of AppModel and manages files in a real directory, default ~/.ssh.
/// Persist its read-only mode and target directory separately in UserDefaults, independently of AppSettings.
@MainActor
final class SSHKeyManagerModel: ObservableObject {
    @Published var keys: [SSHKeyItem] = []
    @Published var selectedKeyID: SSHKeyItem.ID?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isLoading = false

    // MARK: - Config tab state (SSHKeyManagerModel+Config.swift)
    @Published var configEntries: [SSHConfigEntry] = []
    @Published var selectedConfigEntryID: SSHConfigEntry.ID?
    @Published var configMissing = false
    @Published var reachability: [SSHConfigEntry.ID: SSHConfigHostReachabilityStatus] = [:]

    // MARK: - Known Hosts tab state (SSHKeyManagerModel+KnownHosts.swift)
    @Published var knownHostGroups: [KnownHostGroup] = []

    @Published var directoryPath: String {
        didSet { UserDefaults.standard.set(directoryPath, forKey: Self.directoryPathKey) }
    }
    @Published var isReadOnlyModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isReadOnlyModeEnabled, forKey: Self.readOnlyKey) }
    }

    private static let directoryPathKey = "sshKeyManager.directoryPath"
    private static let readOnlyKey = "sshKeyManager.readOnlyMode"
    private static let defaultDirectoryPath = "~/.ssh"

    // MAS selected folders need security-scoped bookmarks for access after relaunch.
    private static let bookmarkKey = "sshKeyManager.directoryBookmark"
    private var scopedURL: URL?

    init() {
        directoryPath = UserDefaults.standard.string(forKey: Self.directoryPathKey) ?? Self.defaultDirectoryPath
        isReadOnlyModeEnabled = UserDefaults.standard.bool(forKey: Self.readOnlyKey)
        if AppEnv.isMAS { restoreBookmark() }
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    /// Actual nonsandbox home directory for picker startup.
    private static var realHomeURL: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func startScopedAccess(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        startScopedAccess(url)
        if stale { saveBookmark(for: url) }
        directoryPath = url.path
    }

    var selectedKey: SSHKeyItem? { keys.first { $0.id == selectedKeyID } }

    func load() {
        isLoading = true
        errorMessage = nil
        let path = directoryPath
        Task {
            do {
                let loaded = try SSHKeyManagerStore.loadKeys(from: path)
                guard path == directoryPath else { return }   // Discard stale results if the directory changed while loading.
                keys = loaded
                if let selectedKeyID, !loaded.contains(where: { $0.id == selectedKeyID }) {
                    self.selectedKeyID = loaded.first?.id
                } else if selectedKeyID == nil {
                    selectedKeyID = loaded.first?.id
                }
                isLoading = false
            } catch {
                guard path == directoryPath else { return }
                keys = []
                selectedKeyID = nil
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Load/reload Keys, Config, and Known Hosts together on initial opening or directory changes.
    func loadAll() {
        // Ask for a folder before sandbox access; real ~/.ssh is outside the container.
        if AppEnv.isMAS, scopedURL == nil {
            errorMessage = String(localized: "Choose your .ssh folder to give ServerDock access to it.")
            chooseDirectory()
            return
        }
        load()
        loadConfig()
        loadKnownHosts()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if AppEnv.isMAS {
            panel.message = String(localized: "Choose your .ssh folder. ServerDock can only access folders you select.")
            panel.directoryURL = Self.realHomeURL.appendingPathComponent(".ssh", isDirectory: true)
            panel.showsHiddenFiles = true
        } else {
            panel.directoryURL = SSHKeyManagerStore.expandedDirectoryURL(for: directoryPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if AppEnv.isMAS {
            saveBookmark(for: url)
            startScopedAccess(url)
        }
        errorMessage = nil
        directoryPath = url.path
        selectedKeyID = nil
        selectedConfigEntryID = nil
        reachability.removeAll()
        loadAll()
    }

    func resetToDefaultDirectory() {
        // Sandbox's default ~/.ssh is container-local; ask for the actual directory.
        if AppEnv.isMAS { chooseDirectory(); return }
        directoryPath = Self.defaultDirectoryPath
        selectedKeyID = nil
        selectedConfigEntryID = nil
        reachability.removeAll()
        loadAll()
    }

    // MARK: - Mutations (check read-only mode first)

    func generate(_ request: SSHKeyGenerationRequest) {
        guard guardWritable() else { return }
        do {
            let id = try SSHKeyManagerStore.generateKey(request, in: directoryPath)
            load()
            selectedKeyID = id
            notice = String(localized: "Generated \(request.fileName)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ key: SSHKeyItem, to newName: String) {
        guard guardWritable() else { return }
        do {
            let id = try SSHKeyManagerStore.rename(key, to: newName)
            load()
            selectedKeyID = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicate(_ key: SSHKeyItem, to newName: String) {
        guard guardWritable() else { return }
        do {
            let id = try SSHKeyManagerStore.duplicate(key, to: newName)
            load()
            selectedKeyID = id
            notice = String(localized: "Duplicated \(key.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ key: SSHKeyItem) {
        guard guardWritable() else { return }
        do {
            try SSHKeyManagerStore.delete(key)
            notice = String(localized: "Deleted \(key.name)")
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateComment(_ key: SSHKeyItem, comment: String) {
        guard guardWritable() else { return }
        do {
            try SSHKeyManagerStore.updateComment(for: key, comment: comment)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func changePassphrase(_ key: SSHKeyItem, oldPassphrase: String, newPassphrase: String) {
        guard guardWritable() else { return }
        do {
            try SSHKeyManagerStore.changePassphrase(for: key, oldPassphrase: oldPassphrase, newPassphrase: newPassphrase)
            notice = key.isPassphraseProtected
                ? String(localized: "Changed passphrase for \(key.name)")
                : String(localized: "Added passphrase for \(key.name)")
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func availableName(for baseName: String) -> String {
        SSHKeyManagerStore.availableKeyName(for: baseName, in: directoryPath)
    }

    // MARK: - Read-only copy/view operations (allowed in read-only mode)

    func copyPublicKey(_ key: SSHKeyItem) {
        guard let path = key.publicKeyPath, let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            errorMessage = String(localized: "No public key file for \(key.name)")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        notice = String(localized: "Public key copied to the clipboard")
    }

    func copyPrivateKey(_ key: SSHKeyItem) {
        guard let path = key.privateKeyPath, let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            errorMessage = String(localized: "No private key file for \(key.name)")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
        notice = String(localized: "Private key copied to the clipboard")
    }

    func copyFingerprint(_ key: SSHKeyItem) {
        guard !key.fingerprint.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.fingerprint, forType: .string)
        notice = String(localized: "Fingerprint copied to the clipboard")
    }

    func revealInFinder(_ key: SSHKeyItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.filePath)])
    }

    func guardWritable() -> Bool {
        guard isReadOnlyModeEnabled else { return true }
        errorMessage = SSHKeyManagerError.readOnlyModeEnabled.localizedDescription
        return false
    }
}
