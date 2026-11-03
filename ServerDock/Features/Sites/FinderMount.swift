import Foundation
import AppKit
import NetFS

/// Mount SMB/WebDAV under /Volumes for Finder/all-app access.
/// Unlike hidden browser-only mounts, these survive app exit and are ejected through Finder.
enum FinderMount {
    /// Return the actual mount path, reusing an existing mount if present.
    static func mount(_ site: Site, password: String) async throws -> URL {
        guard let url = Self.url(for: site) else { throw SiteError(String(localized: "Invalid server address.")) }
        let user = site.username, pw = password
        let (result, path): (Int32, String?) = await Task.detached {
            let open = NSMutableDictionary()
            open[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
            if user.isEmpty && site.kind == .smb { open[kNetFSUseGuestKey as String] = true }
            var points: Unmanaged<CFArray>?
            let r = NetFSMountURLSync(url as CFURL, nil,
                                      user.isEmpty ? nil : user as CFString,
                                      user.isEmpty ? nil : pw as CFString,
                                      open, nil, &points)
            return (r, (points?.takeRetainedValue() as? [String])?.first)
        }.value
        if result == 0, let path { return URL(fileURLWithPath: path, isDirectory: true) }
        if result == EEXIST, site.kind == .smb, let existing = SMBBackend.existingMount(host: site.host.trimmingCharacters(in: .whitespaces), port: site.port,
                                                                                       share: site.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))) {
            return existing
        }
        throw SiteError(SMBBackend.describe(result == 0 ? Int32(EIO) : result))
    }

    /// Reveal the mounted directory in Finder.
    static func mountAndReveal(_ site: Site, password: String) async throws {
        let mp = try await mount(site, password: password)
        await MainActor.run { _ = NSWorkspace.shared.open(mp) }
    }

    static func supports(_ site: Site) -> Bool {
        AppEnv.smbEnabled && (site.kind == .smb || site.kind == .webdav)
    }

    private static func url(for site: Site) -> URL? {
        var h = site.host.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var c = URLComponents()
        switch site.kind {
        case .smb:
            c.scheme = "smb"; c.host = h
            if site.port > 0 && site.port != 445 { c.port = site.port }
            let share = site.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            c.percentEncodedPath = "/" + HTTPSupport.encodePath(share.split(separator: "/").map(String.init))
        case .webdav:
            c.scheme = site.useTLS ? "https" : "http"; c.host = h
            if site.port > 0 { c.port = site.port }
            c.percentEncodedPath = "/" + HTTPSupport.encodePath(SitePath.components(site.path))
        default: return nil
        }
        return c.url
    }
}
