import Foundation

/// Local Mac filesystem backend; RemoteFS delegates here for SSHConnection.isLocal instead of SFTP/SSH,
/// allowing existing trees/editors/favorites/transfers to work locally unchanged.
/// Run all blocking I/O on background threads.
enum LocalFS {
    typealias Failure = RemoteFSError

    private static func bg<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private static func message(_ e: Error, fallback: String) -> RemoteFSError {
        let ns = e as NSError
        let perm = ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError
            || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)))
        let missing = ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
        if perm { return RemoteFSError(message: String(localized: "No access permission"), isPermission: true) }
        if missing { return RemoteFSError(message: String(localized: "File Doesn't Exist")) }
        return RemoteFSError(message: fallback)
    }

    static func versionToken(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let m = a[.modificationDate] as? Date, let s = a[.size] as? NSNumber else { return nil }
        return "\(Int(m.timeIntervalSince1970)):\(s.int64Value)"
    }

    // MARK: - Listing / home

    static func home() -> String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func list(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        await bg {
            let fm = FileManager.default
            do {
                let names = try fm.contentsOfDirectory(atPath: path)
                var files: [RemoteFile] = []
                files.reserveCapacity(names.count)
                for name in names {
                    let full = path == "/" ? "/" + name : path + "/" + name
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    var kind: RemoteFile.Kind = .file
                    switch attrs?[.type] as? FileAttributeType {
                    case .typeDirectory: kind = .directory
                    case .typeSymbolicLink:
                        var isDir: ObjCBool = false
                        kind = (fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue) ? .directory : .symlink
                    case .typeRegular: kind = .file
                    default: kind = .other
                    }
                    files.append(RemoteFile(name: name, path: full, kind: kind,
                                            size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                                            modified: attrs?[.modificationDate] as? Date))
                }
                files.sort { a, b in
                    if a.isDir != b.isDir { return a.isDir }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                return .success(files)
            } catch {
                let ns = error as NSError
                if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
                    return .failure(RemoteFSError(message: String(localized: "Directory doesn't exist")))
                }
                return .failure(message(error, fallback: String(localized: "Failed to list directory")))
            }
        }
    }

    // MARK: - Read / write

    static func read(_ path: String, limit: Int) async -> Result<(data: Data, version: String?), RemoteFSError> {
        await bg {
            do {
                let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? fh.close() }
                let data = try fh.read(upToCount: limit) ?? Data()
                return .success((data, versionToken(path)))
            } catch {
                return .failure(message(error, fallback: String(localized: "Couldn't read file")))
            }
        }
    }

    /// Write a temporary file and atomically replace, preserving permissions; mismatched expectedVersion conflicts.
    static func write(_ path: String, data: Data, expectedVersion: String?) async -> Result<String, RemoteFSError> {
        await bg {
            let fm = FileManager.default
            if fm.fileExists(atPath: path), let exp = expectedVersion, !exp.isEmpty, versionToken(path) != exp {
                return .failure(RemoteFSError(message: String(localized: "The file was modified by another program or session"), isConflict: true))
            }
            let tmp = path + ".serverdock-tmp"
            do {
                let perms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions]
                try data.write(to: URL(fileURLWithPath: tmp))
                if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp) }
                if fm.fileExists(atPath: path) {
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
                } else {
                    try fm.moveItem(atPath: tmp, toPath: path)
                }
                return .success(versionToken(path) ?? "")
            } catch {
                try? fm.removeItem(atPath: tmp)
                return .failure(message(error, fallback: String(localized: "Save failed")))
            }
        }
    }

    // MARK: - File operations

    static func mkdir(_ path: String) async -> Result<Void, RemoteFSError> {
        await bg {
            do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false); return .success(()) }
            catch { return .failure(message(error, fallback: String(localized: "Couldn't Create Folder"))) }
        }
    }

    static func createFile(_ path: String) async -> Result<Void, RemoteFSError> {
        await bg {
            guard !FileManager.default.fileExists(atPath: path),
                  FileManager.default.createFile(atPath: path, contents: Data()) else {
                return .failure(RemoteFSError(message: String(localized: "Couldn't create file (it may already exist or you lack permission)")))
            }
            return .success(())
        }
    }

    /// Prefer moving local items to Trash for recovery; delete only if trashing fails.
    static func delete(_ path: String) async -> Result<Void, RemoteFSError> {
        await bg {
            let fm = FileManager.default
            do {
                do { try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
                catch { try fm.removeItem(atPath: path) }
                return .success(())
            } catch {
                return .failure(message(error, fallback: String(localized: "Delete failed")))
            }
        }
    }

    static func rename(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
        await bg {
            if FileManager.default.fileExists(atPath: to) {
                return .failure(RemoteFSError(message: String(localized: "Target name already exists")))
            }
            do { try FileManager.default.moveItem(atPath: from, toPath: to); return .success(()) }
            catch { return .failure(message(error, fallback: String(localized: "Rename Failed"))) }
        }
    }

    static func chmod(_ path: String, mode: String) async -> Result<Void, RemoteFSError> {
        await bg {
            guard let m = Int(mode, radix: 8) else { return .failure(RemoteFSError(message: String(localized: "Invalid permission value"))) }
            do { try FileManager.default.setAttributes([.posixPermissions: m], ofItemAtPath: path); return .success(()) }
            catch { return .failure(message(error, fallback: String(localized: "Failed to change permissions"))) }
        }
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func statPerms(_ path: String) async -> Result<Int, RemoteFSError> {
        await bg {
            if let p = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber {
                return .success(p.intValue & 0o7777)
            }
            return .failure(RemoteFSError(message: String(localized: "Couldn't read permissions")))
        }
    }

    // MARK: - Copy (upload/download)

    /// Local copy appends at startOffset>0 for resume; control provides progress/cancellation.
    static func copy(from src: String, to dst: String, startOffset: Int64, control: UploadControl) async -> UploadOutcome {
        await bg {
            let fm = FileManager.default
            guard let input = FileHandle(forReadingAtPath: src) else { return .failed(String(localized: "No read permission")) }
            defer { try? input.close() }
            if startOffset <= 0 || !fm.fileExists(atPath: dst) { fm.createFile(atPath: dst, contents: nil) }
            guard let out = FileHandle(forWritingAtPath: dst) else { return .failed(String(localized: "Couldn't write to local file")) }
            defer { try? out.close() }
            do {
                if startOffset > 0 { try input.seek(toOffset: UInt64(startOffset)); _ = try out.seekToEnd() }
                var sent = max(0, startOffset)
                control.setSent(sent)
                while true {
                    switch control.signal {
                    case .cancel: return .cancelled
                    case .pause: return .paused
                    default: break
                    }
                    guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                    try out.write(contentsOf: chunk)
                    sent += Int64(chunk.count)
                    control.setSent(sent)
                }
                return .completed
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Shell execution

    /// Local RemoteFS.run counterpart uses /bin/sh -c; timeout terminates and returns code -1.
    static func runShell(_ command: String, stdin: Data?, timeout: Double) async -> (data: Data, stderr: Data, code: Int32) {
        await bg {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
            do { try p.run() } catch { return (Data(), Data(error.localizedDescription.utf8), -1) }
            var outData = Data(), errData = Data()
            let group = DispatchGroup()
            group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            if let stdin {
                try? inp.fileHandleForWriting.write(contentsOf: stdin)
                try? inp.fileHandleForWriting.close()
            }
            let deadline = DispatchTime.now() + timeout
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
            if done.wait(timeout: deadline) == .timedOut {
                p.terminate()
                _ = done.wait(timeout: .now() + 2)
                group.wait()
                return (outData, errData, -1)
            }
            group.wait()
            return (outData, errData, p.terminationStatus)
        }
    }
}
