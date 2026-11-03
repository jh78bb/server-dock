import AppKit
import Foundation

/// Read-only known_hosts viewing with line deletion; content editing is omitted in v1 because changing keys is risky.
extension SSHKeyManagerModel {
    func loadKnownHosts() {
        let path = directoryPath
        do {
            let entries = try KnownHostsManagerStore.loadEntries(from: path)
            guard path == directoryPath else { return }
            knownHostGroups = KnownHostGroup.group(entries)
        } catch {
            guard path == directoryPath else { return }
            knownHostGroups = []
            errorMessage = error.localizedDescription
        }
    }

    func deleteKnownHost(_ entry: KnownHostEntry) {
        guard guardWritable() else { return }
        do {
            try KnownHostsManagerStore.delete(entry, inDirectory: directoryPath)
            notice = String(localized: "Removed \(entry.displayName) from known_hosts")
            loadKnownHosts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete all known_hosts entries for a host/IP together; one alias may have multiple key-type rows.
    func deleteKnownHostGroup(_ group: KnownHostGroup) {
        guard guardWritable() else { return }
        do {
            try KnownHostsManagerStore.delete(group.entries, inDirectory: directoryPath)
            notice = String(localized: "Removed \(group.entries.count) entries for \(group.host)")
            loadKnownHosts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyKnownHostFingerprint(_ entry: KnownHostEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.fingerprint, forType: .string)
        notice = String(localized: "Fingerprint copied to the clipboard")
    }
}
