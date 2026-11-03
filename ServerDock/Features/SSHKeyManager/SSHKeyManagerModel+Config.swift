import AppKit
import Foundation

/// Create/edit/delete ~/.ssh/config Host blocks and check reachability.
extension SSHKeyManagerModel {
    var selectedConfigEntry: SSHConfigEntry? { configEntries.first { $0.id == selectedConfigEntryID } }

    func loadConfig() {
        let path = directoryPath
        do {
            let loaded = try SSHConfigManagerStore.loadEntries(from: path)
            guard path == directoryPath else { return }
            configEntries = loaded
            configMissing = false
            if let selectedConfigEntryID, !loaded.contains(where: { $0.id == selectedConfigEntryID }) {
                self.selectedConfigEntryID = loaded.first?.id
            } else if selectedConfigEntryID == nil {
                selectedConfigEntryID = loaded.first?.id
            }
            checkReachabilityIfNeeded()
        } catch {
            guard path == directoryPath else { return }
            configEntries = []
            if case SSHConfigManagerError.configMissing = error {
                configMissing = true
            } else {
                configMissing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func addConfigHost(_ request: SSHConfigHostSaveRequest) {
        guard guardWritable() else { return }
        do {
            try SSHConfigManagerStore.addHost(request, inDirectory: directoryPath)
            loadConfig()
            selectedConfigEntryID = configEntries.last(where: { $0.host == request.trimmedHost })?.id
            notice = String(localized: "Added Host \(request.trimmedHost)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateConfigHost(_ entry: SSHConfigEntry, with request: SSHConfigHostSaveRequest) {
        guard guardWritable() else { return }
        do {
            try SSHConfigManagerStore.replaceHost(entry, with: request, inDirectory: directoryPath)
            loadConfig()
            selectedConfigEntryID = configEntries.last(where: { $0.host == request.trimmedHost })?.id
            notice = String(localized: "Updated Host \(request.trimmedHost)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteConfigHost(_ entry: SSHConfigEntry) {
        guard guardWritable() else { return }
        do {
            try SSHConfigManagerStore.deleteHost(entry, inDirectory: directoryPath)
            notice = String(localized: "Deleted Host \(entry.host)")
            loadConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createEmptyConfigIfMissing() {
        guard guardWritable() else { return }
        do {
            let url = SSHConfigManagerStore.configURL(for: directoryPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                try "".write(to: url, atomically: true, encoding: .utf8)
            }
            loadConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyConfigField(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notice = String(localized: "Copied to the clipboard")
    }

    /// Probe all resolvable listed hosts, skipping wildcard/Match blocks, and write results to reachability.
    func checkReachabilityIfNeeded() {
        for entry in configEntries {
            guard reachability[entry.id] == nil else { continue }
            guard case .target(let target) = SSHHostReachabilityResolver.resolveTarget(for: entry) else { continue }
            reachability[entry.id] = .checking
            Task {
                let result = await SSHHostReachabilityChecker.check(target: target, timeout: .seconds(4))
                guard configEntries.contains(where: { $0.id == entry.id }) else { return }
                switch result {
                case .reachable: reachability[entry.id] = .reachable
                case .unreachable: reachability[entry.id] = .unreachable
                case .error: reachability[entry.id] = .error
                }
            }
        }
    }

    func invalidateConfigHostReachability() {
        reachability.removeAll()
        checkReachabilityIfNeeded()
    }
}
