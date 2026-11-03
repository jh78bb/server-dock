import Foundation
import NetFS

/// SMB uses NetFS to mount privately outside Finder, then ordinary file APIs.
/// The system SMB client supplies macOS SMB2/3, signing/encryption, and Kerberos/NTLM behavior.
/// Unsupported in MAS because sandbox mounting is unavailable.
final class SMBBackend: SiteBackend {
    private let site: Site
    private let password: String
    private var mountPoint: URL?            // Actual mounted share path used for file access.
    private var ownedDir: URL?              // Container directory owned by this instance; nil when reusing an externally mounted share.
    private let lock = NSLock()

    init(site: Site, password: String) {
        self.site = site
        self.password = password
    }

    deinit { Self.release(mount: mountPoint, ownedDir: ownedDir) }

    private static var mountRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
            .appendingPathComponent("smb-mounts", isDirectory: true)
    }

    /// Clean stale mounts from crashed previous runs once at startup.
    static func cleanupStaleMounts() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: mountRoot, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            release(mount: subs.first, ownedDir: dir)
            for extra in subs.dropFirst() { release(mount: extra, ownedDir: dir) }
        }
    }

    /// Unmount and remove only empty directories; never use recursive removeItem because failed unmount
    /// would delete actual server files. rmdir only removes empty directories.
    private static func release(mount: URL?, ownedDir: URL?) {
        guard let ownedDir else { return }   // Never touch mounts owned by Finder/others.
        if let mount {
            _ = Darwin.unmount(mount.path, 0)
            _ = Darwin.rmdir(mount.path)
        }
        _ = Darwin.rmdir(ownedDir.path)
    }

    /// Return an existing mount of the same share when available.
    static func existingMount(host: String, port: Int = 0, share: String) -> URL? {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return nil }
        let hostPort = port > 0 && port != 445 ? "\(host):\(port)" : host
        let wantedTail = "@\(hostPort)/\(share)".lowercased()
        let wantedPlain = "//\(hostPort)/\(share)".lowercased()
        for i in 0..<Int(n) {
            var e = buf[i]
            let type = withUnsafePointer(to: &e.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
            guard type == "smbfs" else { continue }
            let from = withUnsafePointer(to: &e.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) } }.lowercased()
            let on = withUnsafePointer(to: &e.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) } }
            if from.hasSuffix(wantedTail) || from == wantedPlain { return URL(fileURLWithPath: on, isDirectory: true) }
        }
        return nil
    }

    private func currentMount() -> URL? { lock.lock(); defer { lock.unlock() }; return mountPoint }
    private func setMounts(_ mount: URL?, owned: URL?) { lock.lock(); mountPoint = mount; ownedDir = owned; lock.unlock() }
    private func takeMount() -> (URL?, URL?) { lock.lock(); defer { lock.unlock() }; let r = (mountPoint, ownedDir); mountPoint = nil; ownedDir = nil; return r }

    private func root() throws -> URL {
        guard let m = currentMount() else { throw SiteError(String(localized: "Not connected.")) }
        return m
    }

    /// Map site paths into mounted URLs; SitePath.normalize prevents .. escapes.
    private func local(_ path: String) throws -> URL {
        var u = try root()
        for c in SitePath.components(path) { u.appendPathComponent(c) }
        return u
    }

    func connect() async throws {
        if (try? root()) != nil { return }
        let s = site, pw = password
        let host = s.host.trimmingCharacters(in: .whitespaces)
        let share = s.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let dir = Self.mountRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // NetFS creates a share-named subdirectory and returns actual paths through mountpoints.
        let (result, mounted): (Int32, String?) = await Task.detached {
            var comps = URLComponents()
            comps.scheme = "smb"
            comps.host = host
            if s.port > 0 && s.port != 445 { comps.port = s.port }
            comps.percentEncodedPath = "/" + HTTPSupport.encodePath(share.split(separator: "/").map(String.init))
            guard let url = comps.url else { return (Int32(EINVAL), nil) }

            let open = NSMutableDictionary()
            open[kNAUIOptionKey as String] = kNAUIOptionNoUI as String          // Fail without showing a login dialog.
            if s.username.isEmpty { open[kNetFSUseGuestKey as String] = true }
            let mount = NSMutableDictionary()
            mount[kNetFSMountFlagsKey as String] = 0x0010_0000                    // MNT_DONTBROWSE hides from Finder/Desktop.
            var points: Unmanaged<CFArray>?
            let r = NetFSMountURLSync(url as CFURL, dir as CFURL,
                                      s.username.isEmpty ? nil : s.username as CFString,
                                      s.username.isEmpty ? nil : pw as CFString,
                                      open, mount, &points)
            let first = (points?.takeRetainedValue() as? [String])?.first
            return (r, first)
        }.value

        if result == 0, let mounted {
            setMounts(URL(fileURLWithPath: mounted, isDirectory: true), owned: dir)
            return
        }
        Self.release(mount: nil, ownedDir: dir)
        // Reuse Finder/other existing share mounts without unmounting them later.
        if result == EEXIST, let existing = Self.existingMount(host: host, port: s.port, share: share) {
            setMounts(existing, owned: nil)
            return
        }
        throw SiteError(Self.describe(result == 0 ? Int32(EIO) : result))
    }

    static func describe(_ code: Int32) -> String {
        switch code {
        case 13, 80, -6600: return String(localized: "Authentication failed. Check the username and password.")   // EACCES / EAUTH / kNetAuthErrorInternal
        case 2, 64, 65, 60, 61: return String(localized: "Couldn't reach the server, or the share doesn't exist.")   // ENOENT / EHOSTDOWN / EHOSTUNREACH / ETIMEDOUT / ECONNREFUSED
        case 17: return String(localized: "This share is already mounted.")
        default: return String(localized: "Couldn't connect to the SMB share (error \(code)).")
        }
    }

    func list(_ path: String) async throws -> [SiteEntry] {
        try await connect()
        let dir = SitePath.normalize(path)
        let url = try local(dir)
        return try await Task.detached {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            return items.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                let isDir = v?.isDirectory ?? false
                return SiteEntry(name: u.lastPathComponent, path: SitePath.join(dir, u.lastPathComponent), isDir: isDir,
                                 size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate)
            }
        }.value
    }

    func download(_ entry: SiteEntry, to dst: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await ChunkedCopy.copy(from: try local(entry.path), to: dst, progress: progress)
    }

    func upload(_ src: URL, to path: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await ChunkedCopy.copy(from: src, to: try local(path), progress: progress)
    }

    func makeDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(at: try local(path), withIntermediateDirectories: false)
    }

    func delete(_ entry: SiteEntry) async throws {
        let u = try local(entry.path)
        try await Task.detached { try FileManager.default.removeItem(at: u) }.value
    }

    func rename(_ entry: SiteEntry, to newPath: String) async throws {
        let dst = try local(newPath)
        if FileManager.default.fileExists(atPath: dst.path) { throw SiteError(String(localized: "An item with that name already exists.")) }
        try FileManager.default.moveItem(at: try local(entry.path), to: dst)
    }

    func disconnect() async {
        let (m, owned) = takeMount()
        await Task.detached { Self.release(mount: m, ownedDir: owned) }.value
    }
}
