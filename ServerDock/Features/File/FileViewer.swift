import AppKit
import SwiftUI

/// Content type for editor/preview.
enum ViewerMode: Equatable {
    case text          // Editable text.
    case readonlyText  // Binary content forced open as read-only text to prevent corrupting it on save.
    case image
    case binary        // Binary content with an option to force opening as text.
    case tooLarge
}

/// State for one editor/preview tab, cached per tab in AppModel.
/// Per-host sudo password cache, memory-only until app exit; never written to disk/Keychain. Clear on an incorrect password.
final class SudoPasswordCache: @unchecked Sendable {   // Protected by a lock; usable from any thread.
    static let shared = SudoPasswordCache()
    private var passwords: [String: String] = [:]
    private let lock = NSLock()
    func get(_ hostId: String) -> String? { lock.lock(); defer { lock.unlock() }; return passwords[hostId] }
    func set(_ hostId: String, _ pw: String?) { lock.lock(); passwords[hostId] = pw; lock.unlock() }
}

/// Context while the editor waits for a sudo password.
struct SudoPrompt: Identifiable {
    enum Op { case read, write(force: Bool) }
    let id = UUID()
    let op: Op
    let error: String?      // Previous failure reason, such as an incorrect password.
}

@MainActor
final class EditorState: ObservableObject {
    @Published private(set) var file: RemoteFile   // Updated on rename so breadcrumbs, language detection, and save destination follow the new path.
    let host: Host
    private let fs: RemoteFS

    /// Rebind a renamed file to its new path without changing/reloading content; subsequent saves use the new path.
    func rebind(to newFile: RemoteFile) { file = newFile }

    @Published var phase: LoadPhase = .loading
    @Published var mode: ViewerMode = .text
    @Published var text: String = "" {
        didSet { isDirty = (text != savedText) }
    }
    @Published var isDirty = false
    /// Version of the last saved/loaded baseline; increment whenever it changes. The change-bar coordinator snapshots TextView
    /// to reconcile the new baseline. ChangeBarCoordinator anchors markers by character offset directly in the editor,
    /// bypassing delayed line-number updates to prevent misalignment during rapid editing.
    @Published private(set) var savedVersion = 0
    @Published var saving = false
    /// Toolbar Find/Replace request opens the editor search panel.
    @Published var findRequest: FindRequest?
    @Published var saveError: String? = nil
    /// An external modification detected on save causes an optimistic-lock conflict; offer overwrite/reload/cancel.
    @Published var saveConflict = false
    /// sudo mode reads/writes this tab as root. Open/Save with sudo enables it for subsequent Command-S saves too.
    @Published private(set) var useSudo = false
    /// Permission denied on read: offer Open with sudo on the error page.
    @Published var readPermissionDenied = false
    /// Permission denied on save: offer Save with sudo in the toolbar.
    @Published var writePermissionDenied = false
    /// Present the sudo password prompt when non-nil.
    @Published var sudoPrompt: SudoPrompt?
    @Published var image: NSImage? = nil
    @Published var byteSize: Int64 = 0

    private var savedText = ""
    /// File version token (`mtime:size`), recorded on open and updated after save for conflict detection. nil means stat is unavailable; skip detection.
    private var fileVersion: String?
    /// Weak editor-text-view reference; AppModel.focusActiveTab uses it to focus a kept-alive tab when selected.
    weak var focusView: NSView?
    private var rawData = Data()           // Used when forcing a binary file open as text.
    private var loadTask: Task<Void, Never>?
    private var started = false

    // Limits: 100KB for text, 16MB for images.
    private let textLimit = 100_000
    private let imageLimit = 16_000_000

    var canSave: Bool { (mode == .text) && isDirty && !saving }
    var lineCount: Int {
        guard !text.isEmpty else { return 1 }
        return text.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    init(file: RemoteFile, host: Host, fs: RemoteFS) {
        self.file = file
        self.host = host
        self.fs = fs
    }

    /// Load once on first appearance; safe for both openFile and onAppear to call.
    func loadIfNeeded() {
        guard !started else { return }
        load()
    }

    func load() {
        started = true
        loadTask?.cancel()
        phase = .loading
        saveError = nil
        readPermissionDenied = false
        let isImg = Self.isImageName(file.name)
        let limit = isImg ? imageLimit : textLimit
        if useSudo { sudoLoad(password: SudoPasswordCache.shared.get(host.id)); return }
        loadTask = Task {
            let result = await fs.read(file.path, limit: limit + 1)
            if Task.isCancelled { return }
            switch result {
            case .failure(let e):
                readPermissionDenied = e.isPermission
                phase = .error(e.message)
            case .success(let (data, version)):
                apply(data: data, version: version, limit: limit, isImg: isImg)
            }
        }
    }

    /// Classify loaded content as text/image/binary/oversized; shared by regular and sudo reads.
    private func apply(data: Data, version: String?, limit: Int, isImg: Bool) {
        byteSize = file.size > 0 ? file.size : Int64(data.count)
        fileVersion = version            // Record the baseline version for optimistic locking.
        if data.count > limit {
            mode = .tooLarge
            phase = .loaded
            return
        }
        rawData = data
        if isImg {
            if let img = NSImage(data: data) {
                image = img; mode = .image
            } else {
                mode = .binary   // The extension indicates an image, but decoding failed.
            }
        } else if let str = Self.decodeText(data) {
            savedText = str
            text = str
            isDirty = false
            savedVersion &+= 1   // Notify the coordinator to reset to the new baseline.
            mode = .text
        } else {
            mode = .binary
        }
        phase = .loaded
    }

    /// Force binary content open as read-only text with lossy decoding.
    func forceOpenAsText() {
        let str = String(decoding: rawData, as: UTF8.self)
        savedText = str
        text = str
        isDirty = false
        savedVersion &+= 1
        mode = .readonlyText
    }

    func reload() { load() }

    /// Save. `force=true` skips the version check and overwrites, as requested in the conflict dialog.
    func save(force: Bool = false) {
        guard canSave else { return }
        saving = true
        saveError = nil
        let path = file.path
        let payload = Data(text.utf8)
        let snapshot = text
        let expected = force ? nil : fileVersion
        writePermissionDenied = false
        if useSudo { sudoSave(force: force, password: SudoPasswordCache.shared.get(host.id)); return }
        Task {
            let r = await fs.write(path, data: payload, expectedVersion: expected)
            saving = false
            switch r {
            case .success(let newVersion):
                didSave(snapshot: snapshot, newVersion: newVersion)
            case .failure(let e):
                if e.isConflict { saveConflict = true; return }   // Let the view present a dialog instead of treating this as a normal error.
                writePermissionDenied = e.isPermission
                saveError = e.message
            }
        }
    }

    private func didSave(snapshot: String, newVersion: String) {
        savedText = snapshot
        fileVersion = newVersion.isEmpty ? nil : newVersion
        isDirty = (text != savedText)
        savedVersion &+= 1   // After save, update the baseline so the coordinator resets and clears/recomputes change bars.
    }

    // MARK: - sudo

    /// Open with sudo: enable sudo mode and reload, trying passwordless sudo before prompting.
    func openWithSudo() {
        useSudo = true
        load()
    }

    /// Save with sudo: enable sudo mode and save; subsequent Command-S saves in this tab also use sudo.
    func saveWithSudo() {
        useSudo = true
        writePermissionDenied = false
        save()
    }

    func submitSudoPassword(_ password: String) {
        guard let prompt = sudoPrompt else { return }
        sudoPrompt = nil
        switch prompt.op {
        case .read: sudoLoad(password: password)
        case .write(let force): sudoSave(force: force, password: password)
        }
    }

    func cancelSudoPrompt() {
        guard let prompt = sudoPrompt else { return }
        sudoPrompt = nil
        if case .read = prompt.op, phase == .loading {
            useSudo = false
            phase = .error(String(localized: "No read permission"))
            readPermissionDenied = true
        }
        saving = false
    }

    /// Handle sudo errors consistently: prompt for missing/incorrect passwords, clearing invalid cached passwords; return other errors to the caller.
    private func handleSudoFailure(_ f: SudoFailure, op: SudoPrompt.Op, triedPassword: String?) -> String? {
        switch f {
        case .passwordRequired:
            sudoPrompt = SudoPrompt(op: op, error: nil)
            return nil
        case .wrongPassword:
            SudoPasswordCache.shared.set(host.id, nil)
            sudoPrompt = SudoPrompt(op: op, error: triedPassword == nil ? nil : f.message)
            return nil
        default:
            return f.message
        }
    }

    private func sudoLoad(password: String?) {
        loadTask?.cancel()
        phase = .loading
        let isImg = Self.isImageName(file.name)
        let limit = isImg ? imageLimit : textLimit
        let path = file.path
        loadTask = Task {
            let r = await fs.sudoRead(path, limit: limit + 1, password: password)
            if Task.isCancelled { return }
            switch r {
            case .success(let (data, version)):
                if let password { SudoPasswordCache.shared.set(host.id, password) }
                apply(data: data, version: version, limit: limit, isImg: isImg)
            case .failure(let f):
                if let msg = handleSudoFailure(f, op: .read, triedPassword: password) { phase = .error(msg) }
            }
        }
    }

    private func sudoSave(force: Bool, password: String?) {
        saving = true
        let path = file.path
        let payload = Data(text.utf8)
        let snapshot = text
        let expected = force ? nil : fileVersion
        Task {
            let r = await fs.sudoWrite(path, data: payload, expectedVersion: expected, password: password)
            switch r {
            case .success(let newVersion):
                saving = false
                if let password { SudoPasswordCache.shared.set(host.id, password) }
                didSave(snapshot: snapshot, newVersion: newVersion)
            case .failure(.fs(let e)) where e.isConflict:
                saving = false
                saveConflict = true
            case .failure(let f):
                if let msg = handleSudoFailure(f, op: .write(force: force), triedPassword: password) {
                    saving = false
                    saveError = msg
                }
            }
        }
    }

    func cancel() { loadTask?.cancel() }

    // MARK: - Utilities

    static func isImageName(_ name: String) -> Bool {
        let ext = (name.lowercased() as NSString).pathExtension
        return ["png","jpg","jpeg","gif","bmp","webp","ico","tiff","tif","heic","heif"].contains(ext)
    }

    /// Try decoding bytes as text; NUL-containing or non-UTF-8 content is treated as binary.
    static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        // A NUL within the first 8KB strongly indicates binary content.
        let probe = data.prefix(8192)
        if probe.contains(0) { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Fallback: older files commonly use GBK/Latin1.
        if let s = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) { return s }
        return nil
    }
}

// MARK: - Routing view

/// Indent the header/breadcrumbs past the editor gutter to align with the code text.
/// The gutter varies with line-number digits (about 38-52px); this inset covers typical 2-4-digit line numbers.
private let editorHeaderInset: CGFloat = 14

struct FileViewerView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var model: AppModel
    let tabId: Int
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var sudoPassword = ""
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            EditorBreadcrumb(file: state.file, host: state.host, model: model)
            content
                // Clip to bounds so the gutter cannot scroll over the header/breadcrumbs.
                .clipped()
                // Overlay the separator above editor content so gutter repainting cannot cover it during scrolling.
                .overlay(alignment: .top) {
                    Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
                }
        }
        .background(Pal.base)
        .onAppear { state.loadIfNeeded() }
        // For optimistic-lock conflicts on save, show overwrite/reload/cancel in a custom dialog to prevent silent data loss.
        .overlay {
            ZStack {
                if state.saveConflict {
                    SaveConflictDialog(
                        onOverwrite: { state.saveConflict = false; state.save(force: true) },
                        onReload: { state.saveConflict = false; state.reload() },
                        onCancel: { state.saveConflict = false }
                    )
                    .transition(.opacity)
                }
            }
            // When no dialog is present, the overlay must not hit-test; a lingering transition layer would block the editor (as in ServerDockApp).
            .allowsHitTesting(state.saveConflict)
        }
        .animation(.easeOut(duration: 0.16), value: state.saveConflict)
        // Cache sudo passwords per host in memory for this app run only; never persist them.
        .alert("sudo Password", isPresented: Binding(
            get: { state.sudoPrompt != nil },
            set: { if !$0, state.sudoPrompt != nil { state.cancelSudoPrompt() } }
        )) {
            SecureField("Password", text: $sudoPassword)
            Button("OK") {
                let pw = sudoPassword
                sudoPassword = ""
                state.submitSudoPassword(pw)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { sudoPassword = ""; state.cancelSudoPrompt() }
        } message: {
            if let err = state.sudoPrompt?.error {
                Text(verbatim: err)
            } else {
                Text("Enter the sudo password for \(state.host.ssh?.user ?? "") on \(state.host.name). It's kept in memory only until ServerDock quits.")
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            FileTypeIcon(file: state.file, size: 13)
            Text(state.file.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                .lineLimit(1)
            if state.isDirty {
                Circle().fill(Pal.yellow).frame(width: 6, height: 6)
            }
            if state.useSudo {
                Text(verbatim: "sudo")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Pal.red)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .help(String(localized: "This file is read and saved as root via sudo"))
            }

            Spacer(minLength: 8)

            if let err = state.saveError {
                Text(err).font(.system(size: 11)).foregroundStyle(Pal.red)
                    .lineLimit(1).truncationMode(.middle)
                if state.writePermissionDenied, state.host.ssh != nil {
                    Button { state.saveWithSudo() } label: {
                        Label("Save with sudo", lucideSymbol: "lock.open")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Pal.tint)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }

            switch state.mode {
            case .text, .readonlyText:
                Text("\(state.lineCount) lines").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Text(humanSize(state.byteSize)).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            case .image:
                if let img = state.image {
                    Text("\(Int(img.size.width))×\(Int(img.size.height))")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                Text(humanSize(state.byteSize)).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            default:
                EmptyView()
            }

            if state.mode == .text || state.mode == .readonlyText {
                findMenu
                toggleButton("text.append", on: settings.editorWrapLines,
                             help: settings.editorWrapLines ? String(localized: "Turn Off Word Wrap") : String(localized: "Turn On Word Wrap")) {
                    settings.editorWrapLines.toggle()
                }
                fontSizeMenu
                toggleButton("map", on: settings.editorMinimap,
                             help: settings.editorMinimap ? String(localized: "Hide Thumbnails") : String(localized: "Show Thumbnails")) {
                    settings.editorMinimap.toggle()
                }
            }

            moreMenu
            helpButton

            if state.mode == .text {
                Button { state.save() } label: {
                    HStack(spacing: 5) {
                        if state.saving { ProgressView().controlSize(.small).scaleEffect(0.7) }
                        else { Image(lucideSymbol: "square.and.arrow.down").font(.system(size: 11, weight: .semibold)) }
                        Text("Save").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(state.canSave ? Pal.tint : Pal.overlay.opacity(0.5))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(state.canSave ? Pal.tint.opacity(0.12) : Pal.fill(0.04),
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .pointerCursor(state.canSave)
                .disabled(!state.canSave)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.leading, editorHeaderInset).padding(.trailing, 12).padding(.vertical, 6)
    }

    private func iconButton(_ symbol: String, help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(lucideSymbol: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    /// Toggle icon communicates on/off through color.
    private func toggleButton(_ symbol: String, on: Bool, help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(lucideSymbol: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Pal.tint : Pal.overlay)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    private var fontSizeMenu: some View {
        Menu {
            Button { settings.editorFontSize = min(settings.editorFontSize + 1, 28) } label: {
                Label("Increase Font Size", lucideSymbol: "plus.magnifyingglass")
            }
            Button { settings.editorFontSize = max(settings.editorFontSize - 1, 9) } label: {
                Label("Decrease Font Size", lucideSymbol: "minus.magnifyingglass")
            }
            Button { settings.editorFontSize = 12 } label: {
                Label("Reset Font Size", lucideSymbol: "arrow.counterclockwise")
            }
        } label: {
            Image(lucideSymbol: "textformat.size").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .pointerCursor()
        .help(String(localized: "Font Size"))
    }

    private var findMenu: some View {
        Menu {
            Button { state.findRequest = FindRequest(replace: false) } label: {
                Label("Find (⌘F)", lucideSymbol: "magnifyingglass")
            }
            Button { state.findRequest = FindRequest(replace: true) } label: {
                Label("Find and Replace", lucideSymbol: "arrow.left.arrow.right")
            }
        } label: {
            Image(lucideSymbol: "magnifyingglass").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .pointerCursor()
        .help(String(localized: "Find and Replace"))
    }

    private var moreMenu: some View {
        Menu {
            Button { copyPath() } label: {
                Label("Copy File Path", lucideSymbol: "doc.on.doc")
            }
            Button { state.reload() } label: {
                Label("Reload", lucideSymbol: "arrow.clockwise")
            }
            Button { model.openTail(path: state.file.path, host: state.host) } label: {
                Label("Tail (Follow Changes)", lucideSymbol: "text.append")
            }
            let fav = model.isFavorite(state.file.path, hostId: state.host.id)
            Button { model.toggleFavorite(path: state.file.path, isDir: false, hostId: state.host.id) } label: {
                Label(fav ? "Remove from Favorites" : "Add to Favorites", lucideSymbol: fav ? "star.slash" : "star")
            }
            Divider()
            Button { model.jumpToExplorer(path: state.file.path, host: state.host) } label: {
                Label("Reveal in File Tree", lucideSymbol: "sidebar.right")
            }
            Button {
                let dir = (state.file.path as NSString).deletingLastPathComponent
                model.openHostTerminal(state.host, at: dir.isEmpty ? "/" : dir)
            } label: {
                Label("Open Folder in Terminal", lucideSymbol: "terminal")
            }
            Divider()
            Button { model.downloadFiles([state.file], host: state.host) } label: {
                Label("Download", lucideSymbol: "arrow.down.circle")
            }
            ExternalOpenMenu(model: model, file: state.file, host: state.host,
                             contents: { state.mode == .text ? state.text : nil })
        } label: {
            Image(lucideSymbol: "ellipsis").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .pointerCursor()
        .help(String(localized: "More Actions"))
    }

    private var helpButton: some View {
        Button { showHelp = true } label: {
            Image(lucideSymbol: "questionmark.circle").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(String(localized: "What do these buttons do?"))
        .popover(isPresented: $showHelp, arrowEdge: .bottom) { EditorToolbarHelpView() }
    }

    private func copyPath() {
        model.copyRemotePath(state.file.path)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .error(let msg):
            centered {
                VStack(spacing: 10) {
                    Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Pal.yellow)
                    Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                    if state.readPermissionDenied, state.host.ssh != nil {
                        Button { state.openWithSudo() } label: {
                            Label("Open with sudo", lucideSymbol: "lock.open")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Pal.tint)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                    Button("Retry") { state.reload() }.buttonStyle(.plain).pointerCursor().foregroundStyle(Pal.tint)
                }
                .padding(.horizontal, 40)
            }
        case .loaded:
            switch state.mode {
            case .text, .readonlyText:
                // The model caches one NSHostingView-hosted editor per tab, so SwiftUI updates do not recreate its controller.
                // Undo history, cursor, and scroll state survive for the tab's lifetime; avoid setText clearing undo history.
                CachedEditorHost(model: model, tabId: tabId, state: state)
            case .image:
                ImagePreviewView(image: state.image)
            case .binary:
                BinaryNoticeView(file: state.file, size: state.byteSize,
                                 onForceText: { state.forceOpenAsText() })
            case .tooLarge:
                TooLargeNoticeView(size: state.byteSize) {
                    model.downloadFiles([state.file], host: state.host, thenOpen: true)
                }
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func editorFont(size: CGFloat) -> NSFont {
        // Use SF Mono; if NSFont(name:) cannot resolve its family name, fall back to monospacedSystemFont, which is SF Mono on modern macOS.
        for name in ["SF Mono", "SFMono-Regular"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Host each editor subtree once in `NSHostingView` and cache it by tabId in `AppModel` to preserve undo/state.
/// `makeNSView` always returns the cached instance, so outer SwiftUI/representable rebuilds never recreate the inner
/// `TextViewController` or clear its `CEUndoManager` undo stack, cursor, or scroll state during the tab lifetime.
private struct CachedEditorHost: NSViewRepresentable {
    let model: AppModel
    let tabId: Int
    let state: EditorState

    func makeNSView(context: Context) -> NSView {
        if let cached = model.editorHosts[tabId] { return cached }
        let container = NSView()
        let host = NSHostingView(rootView: EditorRoot(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        model.editorHosts[tabId] = container
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The editor root is hosted once and observes theme/settings/state internally for theme, minimap, text, and baseline changes,
/// without relying on outer view reconstruction.
private struct EditorRoot: View {
    @ObservedObject var state: EditorState
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        RemoteCodeEditor(
            text: $state.text,
            editable: state.mode == .text,
            fileName: state.file.name,
            colors: theme.colors,
            isDark: theme.isDark,
            font: FileViewerView.editorFont(size: CGFloat(settings.editorFontSize)),
            showMinimap: settings.editorMinimap,
            wrapLines: settings.editorWrapLines,
            findRequest: state.findRequest,
            savedVersion: state.savedVersion,
            onEditorReady: { [weak state] v in state?.focusView = v }
        )
    }
}

/// Editor toolbar help popover lists icon/name/one-line explanations.
private struct EditorToolbarHelpView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let items: [Item] = [
        Item(symbol: "magnifyingglass", title: String(localized: "Find and Replace"),
             detail: String(localized: "Open the find bar (⌘F), or choose Find and Replace to also replace matches. You can switch between the two with the dropdown at the left of the bar.")),
        Item(symbol: "text.append", title: String(localized: "Word Wrap"),
             detail: String(localized: "Wrap long lines to the window width instead of scrolling sideways.")),
        Item(symbol: "textformat.size", title: String(localized: "Font Size"),
             detail: String(localized: "Make the editor text larger or smaller, or reset it.")),
        Item(symbol: "map", title: String(localized: "Thumbnails"),
             detail: String(localized: "Show or hide the code overview strip on the right.")),
        Item(symbol: "ellipsis", title: String(localized: "More Actions"),
             detail: String(localized: "Copy the file path, reload the file from the server, reveal it in the file panel, open its folder in a terminal, download it, open it in another app, or share it. Edits made in another app are not uploaded back.")),
        Item(symbol: "square.and.arrow.down", title: String(localized: "Save"),
             detail: String(localized: "Write your changes back to the server (⌘S).")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Toolbar Guide").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(lucideSymbol: item.symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Pal.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Pal.solidBase)
    }
}

// MARK: - Breadcrumb path bar (click to navigate the left file explorer)

private struct EditorBreadcrumb: View {
    let file: RemoteFile
    let host: Host
    @ObservedObject var model: AppModel

    private struct Crumb: Identifiable {
        let id: Int
        let name: String
        let path: String
        let isLast: Bool
    }

    private var crumbs: [Crumb] {
        let comps = file.path.split(separator: "/").map(String.init)
        var acc = ""
        var out: [Crumb] = []
        for (i, c) in comps.enumerated() {
            acc += "/" + c
            out.append(Crumb(id: i, name: c, path: acc, isLast: i == comps.count - 1))
        }
        return out
    }

    var body: some View {
        // Reuse tab-bar horizontal scrolling (wheel/swipe); deep paths remain scrollable and path changes scroll to the filename.
        HWheelScroll(pathKey: file.path) {
            HStack(spacing: 5) {
                // Show host/workspace as a distinct small capsule.
                HostPill(name: host.name) { model.jumpToExplorer(path: "/", host: host) }
                ForEach(crumbs) { crumb in
                    HStack(spacing: 4) {
                        Text("/").font(.system(size: 10.5)).foregroundStyle(Pal.overlay.opacity(0.4))
                        CrumbText(name: crumb.name, isLast: crumb.isLast, file: file) {
                            model.jumpToExplorer(path: crumb.path, host: host)
                        }
                    }
                }
            }
            .padding(.leading, editorHeaderInset).padding(.trailing, 12)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 22)
    }
}

/// Host/workspace capsule, visually stronger than directory segments.
private struct HostPill: View {
    let name: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(lucideSymbol: "server.rack").font(.system(size: 9))
                Text(name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(Pal.tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Pal.tint.opacity(hover ? 0.22 : 0.13), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help(String(localized: "Go to Root"))
    }
}

/// Intermediate directories use muted text without icons; the current file has a type icon and primary text color.
private struct CrumbText: View {
    let name: String
    let isLast: Bool
    let file: RemoteFile
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLast {
                    FileTypeIcon(file: file, size: 9.5)
                }
                Text(name)
                    .font(.system(size: 10.5, weight: isLast ? .medium : .regular))
                    .foregroundStyle(isLast ? Pal.text : (hover ? Pal.subtext : Pal.overlay))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)   // Scroll breadcrumbs horizontally instead of truncating file/directory names.
            }
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(hover ? Pal.fill(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help(isLast ? String(localized: "Reveal in File Tree") : String(localized: "Go to This Directory"))
    }
}

// MARK: - Image preview

private struct ImagePreviewView: View {
    let image: NSImage?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CheckerboardBackground()
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .padding(20)
                    }
                } else {
                    Text("Couldn't Display Image").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Zoom controls.
            HStack(spacing: 14) {
                zoomButton("minus.magnifyingglass") { scale = max(0.1, scale - 0.25) }
                Text("\(Int(scale * 100))%").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.subtext).frame(width: 52)
                zoomButton("plus.magnifyingglass") { scale = min(8, scale + 0.25) }
                Divider().frame(height: 14).overlay(Pal.fill(0.1))
                Button("Actual Size") { scale = 1.0 }.buttonStyle(.plain).pointerCursor()
                    .font(.system(size: 12)).foregroundStyle(Pal.tint)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Pal.mantle)
        }
    }

    private func zoomButton(_ symbol: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(lucideSymbol: symbol).font(.system(size: 14)).foregroundStyle(Pal.subtext)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor()
    }
}

/// Checkerboard for transparent backgrounds.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            let cols = Int(size.width / s) + 1
            let rows = Int(size.height / s) + 1
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color(Pal.fill(0.04)))
                }
            }
        }
        .background(Pal.base)
    }
}

// MARK: - Binary / oversized-file notices

private struct BinaryNoticeView: View {
    let file: RemoteFile
    let size: Int64
    let onForceText: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(lucideSymbol: "doc.questionmark").font(.system(size: 34)).foregroundStyle(Pal.overlay)
            Text("Binary file").font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.text)
            Text("\(file.name) · \(humanSize(size))")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
            Button(action: onForceText) {
                Text("Open as Text Anyway").font(.system(size: 12))
                    .foregroundStyle(Pal.tint)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TooLargeNoticeView: View {
    let size: Int64
    let onDownload: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(lucideSymbol: "exclamationmark.arrow.triangle.2.circlepath").font(.system(size: 32)).foregroundStyle(Pal.yellow)
            Text("File Too Large").font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.text)
            Text("\(humanSize(size)) — exceeds the editor's open limit")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
            Button("Download and Open", action: onDownload)
                .buttonStyle(.plain).foregroundStyle(Pal.tint).pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Custom optimistic-lock conflict dialog, matching the [[HostKeyDialog]] card style instead of a system .alert.
/// Compact card with a bottom row of pill buttons: muted red overwrite, gray reload, text-only cancel.
struct SaveConflictDialog: View {
    let onOverwrite: () -> Void
    let onReload: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hovered: Int? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.42 : 0.20).ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(lucideSymbol: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(Pal.yellow)
                    Text("The file was modified externally")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.bottom, 9)

                Text("This file has been modified by another program or session since you opened it. \"Overwrite\" discards the external changes; \"Reload\" discards your unsaved changes.")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .padding(.bottom, 18)

                HStack(spacing: 8) {
                    Spacer()
                    pill(0, String(localized: "Cancel"), fg: Pal.subtext,
                         base: .clear, hover: Pal.fill(0.07), border: .clear, action: onCancel)
                    pill(1, String(localized: "Reload"), fg: Pal.text,
                         base: Pal.fill(0.07), hover: Pal.fill(0.13), border: Pal.fill(0.10), action: onReload)
                    pill(2, String(localized: "Overwrite"), fg: Pal.red,
                         base: Pal.red.opacity(0.12), hover: Pal.red.opacity(0.20),
                         border: Pal.red.opacity(0.28), action: onOverwrite)
                }
            }
            .padding(18)
            .frame(width: 384)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 20, y: 7)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func pill(_ id: Int, _ title: String, fg: Color,
                      base: Color, hover: Color, border: Color,
                      action: @escaping () -> Void) -> some View {
        let isHover = hovered == id
        return Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 6.5)
                .background(isHover ? hover : base, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }
}
