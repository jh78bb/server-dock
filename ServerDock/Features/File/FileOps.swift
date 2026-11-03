import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File-action target backend for rename/permissions/delete/post-upload refresh.
/// FileTreeState and BrowserState implement it to share menus.
@MainActor
protocol FileOpsTarget: AnyObject {
    /// Non-nil handle permits cancellation, especially slow recursive directory deletion.
    func performDelete(_ file: RemoteFile, handle: CommandHandle?) async -> Result<Void, RemoteFSError>
    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError>
    func performChmod(_ file: RemoteFile, mode: String) async -> Result<Void, RemoteFSError>
    func currentPerms(_ file: RemoteFile) async -> Int?
    /// Create a file/folder under dir, then refresh the affected area.
    func performCreate(_ name: String, isDir: Bool, inDir dir: String) async -> Result<Void, RemoteFSError>
}

/// Separate single-file context actions for reuse alongside browser batch-selection menus.
@MainActor @ViewBuilder
func fileOpsMenuItems(file: RemoteFile, host: Host, model: AppModel,
                      target: any FileOpsTarget, onRefresh: @escaping () -> Void) -> some View {
    Group {
        if file.isDir {
            Button { model.beginUpload(into: file, host: host) } label: {
                Label("Upload File…", lucideSymbol: "square.and.arrow.up")
            }
            Button { model.openDiskUsage(path: file.path, host: host) } label: {
                Label("Analyze Disk Usage", lucideSymbol: "chart.bar.xaxis")
            }
            Button { model.fileMenuRequestCreate(isDir: false, inDir: file.path, host: host, target: target) } label: {
                Label("New File", lucideSymbol: "doc.badge.plus")
            }
            Button { model.fileMenuRequestCreate(isDir: true, inDir: file.path, host: host, target: target) } label: {
                Label("New Folder", lucideSymbol: "folder.badge.plus")
            }
            Divider()
        } else {
            Button { model.downloadFiles([file], host: host) } label: {
                Label("Download", lucideSymbol: "square.and.arrow.down")
            }
            if TailSupport.isLikelyText(file.name) {
                Button { model.openTail(path: file.path, host: host) } label: {
                    Label("Tail (Follow Changes)", lucideSymbol: "text.append")
                }
            }
            ExternalOpenMenu(model: model, file: file, host: host)
            if ArchiveKind.detect(file.name) != nil {
                Button { model.requestExtract(file, host: host) } label: {
                    Label("Extract", lucideSymbol: "doc.zipper")
                }
            }
            Divider()
        }
        Button(action: onRefresh) { Label("Refresh", lucideSymbol: "arrow.clockwise") }
        let fav = model.isFavorite(file.path, hostId: host.id)
        Button { model.toggleFavorite(path: file.path, isDir: file.isDir, hostId: host.id) } label: {
            Label(fav ? "Remove from Favorites" : "Add to Favorites", lucideSymbol: fav ? "star.slash" : "star")
        }
        Divider()
        Button { model.fileMenuRequestRename(file, host: host, target: target) } label: {
            Label("Rename", lucideSymbol: "pencil")
        }
        Button { model.fileMenuRequestChmod(file, host: host, target: target) } label: {
            Label("Permissions", lucideSymbol: "lock")
        }
        Divider()
        Button(role: .destructive) {
            model.fileMenuRequestDelete(file, host: host, target: target)
        } label: {
            Label("Delete", lucideSymbol: "trash")
        }
    }
}

extension View {
    /// Shared row menu: directory upload, refresh, rename, permissions, delete.
    /// Both views route rename/permissions/delete through AppModel dialogs and the shared target.
    /// onRefresh is view-specific: sidebar fileMenuRefresh considers editors; browser reloads cwd.
    func fileOpsMenu(file: RemoteFile, host: Host, model: AppModel,
                     target: any FileOpsTarget, onRefresh: @escaping () -> Void) -> some View {
        contextMenu {
            fileOpsMenuItems(file: file, host: host, model: model, target: target, onRefresh: onRefresh)
        }
    }
}


// MARK: - Open in other apps / Share

/// Download to a temporary local URL; edits in external apps never sync back.
/// If contents contains current editor text, write it directly instead of downloading.
extension AppModel {
    /// Choose an associated app for downloaded files; otherwise reveal in Finder.
    func showOpenWithApps(for url: URL) {
        let apps = OpenWithApps.apps(forFileName: url.lastPathComponent)
        guard !apps.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Open downloaded file")
        alert.informativeText = url.lastPathComponent
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for app in apps { picker.addItem(withTitle: app.name) }
        alert.accessoryView = picker
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        if alert.runModal() == .alertFirstButtonReturn {
            let app = apps[picker.indexOfSelectedItem]
            NSWorkspace.shared.open([url], withApplicationAt: app.url,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func exportRemoteFile(_ file: RemoteFile, host: Host, contents: String? = nil) async -> URL? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerDock-Export", isDirectory: true)
        Self.purgeOldExports(in: root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let contents {
                try Data(contents.utf8).write(to: url)
                return url
            }
        } catch {
            keyOpError = error.localizedDescription
            return nil
        }
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return nil }
        switch await RemoteFS(ssh).download(file.path, to: url, control: UploadControl()) {
        case .completed: return url
        case .failed(let msg): keyOpError = msg; return nil
        case .cancelled, .paused: return nil
        }
    }

    /// Remove export folders older than 24 hours.
    private static func purgeOldExports(in root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-24 * 3600)
        for u in items {
            if let d = try? u.resourceValues(forKeys: [.creationDateKey]).creationDate, d < limit {
                try? fm.removeItem(at: u)
            }
        }
    }

    /// Open using the default app when app=nil, otherwise the selected app.
    func openRemoteFileExternally(_ file: RemoteFile, host: Host, contents: String? = nil, with app: URL? = nil) {
        Task { @MainActor in
            guard let url = await exportRemoteFile(file, host: host, contents: contents) else { return }
            if let app {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// System AirDrop/Messages/Mail sharing near the click position.
    func shareRemoteFile(_ file: RemoteFile, host: Host, contents: String? = nil) {
        Task { @MainActor in
            guard let url = await exportRemoteFile(file, host: host, contents: contents),
                  let window = NSApp.keyWindow, let view = window.contentView else { return }
            let p = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            NSSharingServicePicker(items: [url])
                .show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }
}

/// Cache installed associated apps by extension.
@MainActor
enum OpenWithApps {
    struct App: Identifiable {
        let url: URL
        let name: String
        let icon: NSImage
        var id: URL { url }
    }

    private static var cache: [String: [App]] = [:]

    static func apps(forFileName name: String) -> [App] {
        let ext = (name as NSString).pathExtension.lowercased()
        if let hit = cache[ext] { return hit }
        let type = UTType(filenameExtension: ext) ?? .data
        let ws = NSWorkspace.shared
        var apps = ws.urlsForApplications(toOpen: type).prefix(14).map { url -> App in
            let icon = ws.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return App(url: url, name: name, icon: icon)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cache[ext] = apps
        return apps
    }
}

/// Shared Default App/Open With/Share actions for file context and editor More menus.
struct ExternalOpenMenu: View {
    let model: AppModel
    let file: RemoteFile
    let host: Host
    var contents: () -> String? = { nil }

    var body: some View {
        Group {
            Button { model.openRemoteFileExternally(file, host: host, contents: contents()) } label: {
                Label("Open with Default App", lucideSymbol: "arrow.up.forward.app")
            }
            Menu {
                let apps = OpenWithApps.apps(forFileName: file.name)
                if apps.isEmpty {
                    Text("No Apps Found")
                } else {
                    ForEach(apps) { app in
                        Button { model.openRemoteFileExternally(file, host: host, contents: contents(), with: app.url) } label: {
                            Label { Text(verbatim: app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                }
            } label: {
                Label("Open With", lucideSymbol: "app.badge")
            }
            Button { model.shareRemoteFile(file, host: host, contents: contents()) } label: {
                Label("Share…", lucideSymbol: "square.and.arrow.up")
            }
        }
    }
}
