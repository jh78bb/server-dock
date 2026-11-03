import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView   // Change bars need layoutManager.textLineForIndex / textView.textInsets.

/// Code editor wrapping CodeEditSourceEditor's TextKit-based SourceEditor.
/// The library provides highlighting, completion UI, Find/Replace (Command-F), minimap, auto-indent, and bracket matching.
///
/// Pass configuration and fill the available space with `.frame(maxWidth/maxHeight: .infinity)`.
/// Without wrapping, the library expands to max(longest line, viewport) and enables horizontal scrolling, using the vendored CodeEditTextView fix.
/// Upstream 0.12.1 has an inout-shadowing bug that breaks line-width calculation and horizontal scrolling; see LocalPackages/CodeEditTextView.
/// EditorFixer adjusts the view hierarchy for a persistent horizontal scroller and minimap click/content overlap issues.
struct RemoteCodeEditor: View {
    @Binding var text: String        // EditorState.text: remotely loaded content with two-way updates.
    let editable: Bool               // .text → true；.readonlyText → false
    let fileName: String             // Detect the language from the file extension.
    let colors: ThemeColors
    let isDark: Bool
    let font: NSFont
    let showMinimap: Bool
    var wrapLines: Bool = false      // Wrapping off means horizontal scrolling for long lines.
    var findRequest: FindRequest? = nil   // Each toolbar Find/Replace request change opens search.
    let savedVersion: Int            // Baseline version; changes trigger a fresh TextView snapshot and reconciliation.
    var onEditorReady: ((NSView) -> Void)? = nil   // Text-view-ready callback for keep-alive focus registration.

    @State private var editorState = SourceEditorState()
    // Use @StateObject's one-time autoclosure initialization instead of @State, whose default value is recreated
    // and discarded on each body update, needlessly allocating a coordinator on every scroll/edit frame.
    @StateObject private var changeBars = ChangeBarCoordinator()
    @StateObject private var undoBreaker = TypingUndoBreaker()   // Split typing undo groups after an idle pause for finer undo granularity.

    private var language: CodeLanguage {
        // detectLanguageFrom reads only the extension/filename, not disk; fileURLWithPath works for remote files.
        CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: fileName))
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: EditorTheme.serverdock(colors: colors, isDark: isDark),
                    font: font,
                    wrapLines: wrapLines,             // Do not wrap by default; scroll long lines horizontally. The toolbar can enable wrapping.
                    tabWidth: 4
                ),
                behavior: .init(
                    isEditable: editable,
                    isSelectable: true,
                    indentOption: .spaces(count: 4)   // Auto-indent unit.
                ),
                peripherals: .init(
                    showGutter: true,                 // Line numbers.
                    showMinimap: showMinimap,         // Let the library handle minimap hiding/content insets.
                    showFoldingRibbon: false           // Disable the cluttered persistent folding ribbon.
                )
            ),
            state: $editorState,
            // Do not attach tree-sitter for plainText (.txt/.log); avoid setup, parsing, and memory costs,
            // including repeated "setting up with language: plainText" work. Pass nil for normal code highlighting.
            highlightProviders: language.id == .plainText ? [] : nil,
            coordinators: [changeBars, undoBreaker]   // Change bars plus idle-based undo-group splitting.
        )
        // Rebuild the editor when toggling the minimap: EditorFixer removes MinimapView from its superview when hidden,
        // but the library creates it only once. Rebuilding allows it to reappear when enabled again.
        .id(showMinimap)
        // Fill the available width/height, as in the official example, to give the text container a definite viewport size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Adjust only the view hierarchy: persistent horizontal scroller, removed hidden minimap, and insets for the visible minimap.
        .background(EditorFixer(showMinimap: showMinimap))
        .onAppear {
            if let cb = onEditorReady { undoBreaker.registerReady(cb) }
        }
        // On load/save baseline changes, snapshot current TextView content and recompute.
        .onChange(of: savedVersion) { _ in changeBars.markBaselineFromCurrent() }
        .onChange(of: findRequest) { req in
            if let req { undoBreaker.showFind(replace: req.replace) }
        }
    }
}

/// Give every toolbar search request a new ID so onChange always fires.
struct FindRequest: Equatable {
    let id = UUID()
    let replace: Bool
}

/// Fix two CodeEditSourceEditor embedding issues through view-hierarchy adjustments without changing library logic.
/// Use a zero-sized background NSView anchor; showMinimap changes invoke updateNSView.
/// Apply changes asynchronously after this frame's layout/reloadUI/styleScrollView to avoid being overwritten by the library.
///
/// The library hardcodes scrollerStyle = .overlay, showing the scroller only while scrolling.
/// Use .legacy without auto-hiding for a persistent draggable horizontal scrollbar.
///
/// A hidden minimap can still intercept clicks when embedded; removeFromSuperview instead of relying on isHidden.
/// The minimap initially often has zero width when text insets are computed, allowing content underneath it. Once its width is available,
/// post a contentView frame-change notification to trigger updateTextInsets() and keep content left of the minimap.
private struct EditorFixer: NSViewRepresentable {
    let showMinimap: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.schedule(from: nsView, show: showMinimap, attempt: 0)
    }

    /// The scroll view/minimap may be created or sized later; retry until fixed, for up to about 2.1s.
    private static func schedule(from nsView: NSView, show: Bool, attempt: Int) {
        DispatchQueue.main.async {
            let done = editorRoot(from: nsView).map { apply(in: $0, show: show) } ?? false
            if !done && attempt < 14 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    schedule(from: nsView, show: show, attempt: attempt + 1)
                }
            }
        }
    }

    @discardableResult
    private static func apply(in root: NSView, show: Bool) -> Bool {
        guard let scroll = findEditorScrollView(in: root) else { return false }
        // Reset the persistent horizontal scroller each time to counter reloadUI/styleScrollView restoring .overlay.
        if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
        if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
        // Minimap.
        if show {
            guard let minimap = findMinimap(in: root), minimap.frame.width > 1 else { return false }
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
            return true
        } else {
            return removeMinimap(in: root)
        }
    }

    /// Find the nearest ancestor containing the editor scroll view, avoiding stale views left by .id rebuilds.
    private static func editorRoot(from nsView: NSView) -> NSView? {
        var v: NSView? = nsView.superview
        while let cur = v {
            if findEditorScrollView(in: cur) != nil { return cur }
            v = cur.superview
        }
        return nsView.window?.contentView
    }

    private static func removeMinimap(in view: NSView) -> Bool {
        var done = false
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "MinimapView" {
                sub.removeFromSuperview()
                done = true
            } else if removeMinimap(in: sub) {
                done = true
            }
        }
        return done
    }

    private static func findMinimap(in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == "MinimapView" { return view }
        for sub in view.subviews {
            if let m = findMinimap(in: sub) { return m }
        }
        return nil
    }

    private static func findEditorScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, let doc = s.documentView,
           String(describing: type(of: doc)).contains("TextView") {
            return s
        }
        for sub in view.subviews {
            if let s = findEditorScrollView(in: sub) { return s }
        }
        return nil
    }
}

/// CEUndoManager merges adjacent typing in the same direction into one undo group, so one Command-Z can remove a large block
/// and appear to lose undo history. Call breakTypingGroup() after about 0.35s of inactivity
/// so the next input starts a new group. Affect ordinary typing only, preserving atomic indent/comment operations.
final class TypingUndoBreaker: TextViewCoordinator, ObservableObject {
    private weak var controller: TextViewController?
    private var work: DispatchWorkItem?
    /// Notify when the editor text view is ready so the caller can register EditorState.focusView for keep-alive focus.
    private var onTextViewReady: ((NSView) -> Void)?

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }

    func controllerDidAppear(controller: TextViewController) {
        self.controller = controller
        if let tv = controller.textView { onTextViewReady?(tv) }
    }

    /// Set the callback from SwiftUI; register immediately if the controller is ready, covering onAppear/controllerDidAppear ordering.
    func showFind(replace: Bool) { controller?.showFindPanel(replace: replace) }

    func registerReady(_ cb: @escaping (NSView) -> Void) {
        onTextViewReady = cb
        if let tv = controller?.textView { cb(tv) }
    }

    func textViewDidChangeText(controller: TextViewController) {
        self.controller = controller
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.controller?.textView?._undoManager?.breakTypingGroup()
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func destroy() { work?.cancel() }
}

/// Gutter change bars relative to the last save, derived from EditorState's line diff.
/// Use TextViewCoordinator to obtain the controller and overlay the gutter with an equally positioned layer,
/// drawing a theme-colored bar beside each changed line without modifying library logic or intercepting clicks.
/// Sticky change-bar coordinator: anchor markers by character offset in the current text coordinate space.
/// NSTextStorageDelegate shifts anchors synchronously on every edit,
/// preventing async lag from misaligning them. Background hunk diff provides authoritative reconciliation, applied only if the generation still matches.
/// Snapshot the saved baseline directly from TextView to avoid delayed SwiftUI binding updates.
final class ChangeBarCoordinator: NSObject, TextViewCoordinator, NSTextStorageDelegate, ObservableObject {
    private weak var controller: TextViewController?
    private var barView: ChangeBarView?
    private var observers: [NSObjectProtocol] = []

    private var baselineLines: [String] = [""]    // Split the baseline on "\n", preserving offset coordinates without CRLF normalization.
    private var dirtyOffsets: Set<Int> = []        // UTF-16 offsets of changed line starts in current-text coordinates.

    private var recomputeWork: DispatchWorkItem?
    private var recomputeToken = 0
    private var editGeneration = 0                  // Increment on each edit to discard stale reconciliation results when they return to the main thread.
    private var baselineEstablished = false         // Do not mistake edited content for a new baseline when toggling the minimap rebuilds the editor.
    private let diffQueue = DispatchQueue(label: "serverdock.changebar.diff", qos: .userInitiated)

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }

    func controllerDidAppear(controller: TextViewController) {
        self.controller = controller
        install()                                  // The scrollView/textView are ready and the gutter is already installed; place the overlay above it.
        controller.textView?.addStorageDelegate(self)
        // Initialize the baseline from current content only once; skip on minimap rebuilds to preserve markers.
        // Actual save/load baseline updates always use savedVersion -> markBaselineFromCurrent.
        if !baselineEstablished { markBaselineFromCurrent() }
    }

    /// After load/save, SwiftUI's savedVersion update snapshots the current TextView as the new baseline and reconciles immediately.
    func markBaselineFromCurrent() {
        guard let s = controller?.textView?.string else { return }
        baselineEstablished = true
        baselineLines = Self.splitLines(s)
        dirtyOffsets = []
        pushToView()
        recomputeNow()
    }

    // MARK: NSTextStorageDelegate - shift sticky anchors synchronously on every edit
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        editGeneration &+= 1
        let editStart = editedRange.location
        let oldEnd = editedRange.location + editedRange.length - delta   // Previous end of the replaced range.
        // For full-document replacement (load/format), skip incremental updates and reconcile to avoid flashing all lines as changed.
        if editStart == 0 && editedRange.length == textStorage.length && oldEnd != editedRange.length {
            dirtyOffsets = []
            pushToView(); scheduleRecompute(); return
        }
        dirtyOffsets = Self.shift(dirtyOffsets, editStart: editStart, oldEnd: oldEnd, delta: delta)
        // Mark the edited line immediately by its start offset, without waiting for reconciliation.
        let ns = textStorage.string as NSString
        if editStart <= ns.length {
            dirtyOffsets.insert(ns.lineRange(for: NSRange(location: editStart, length: 0)).location)
        }
        pushToView()
        scheduleRecompute()
    }

    /// Shift offsets for one edit (editStart, oldEnd, delta); discard anchors in the replaced range and let reconciliation rebuild them.
    private static func shift(_ offsets: Set<Int>, editStart: Int, oldEnd: Int, delta: Int) -> Set<Int> {
        var out = Set<Int>()
        for o in offsets {
            if o <= editStart { out.insert(o) }
            else if o >= oldEnd { out.insert(o + delta) }
        }
        return out
    }

    // MARK: Authoritative background reconciliation
    private func scheduleRecompute() {
        recomputeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runRecompute() }
        recomputeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
    private func recomputeNow() { recomputeWork?.cancel(); runRecompute() }
    private func runRecompute() {
        guard let tv = controller?.textView else { return }
        let snapshot = tv.string
        let gen = editGeneration
        let base = baselineLines
        recomputeToken &+= 1
        let token = recomputeToken
        diffQueue.async { [weak self] in
            let dirty = Self.computeOffsets(curText: snapshot, baselineLines: base)
            DispatchQueue.main.async {
                guard let self, self.recomputeToken == token, self.editGeneration == gen else { return }  // Discard results made stale by newer edits.
                self.dirtyOffsets = dirty
                self.pushToView()
            }
        }
    }

    private func pushToView() {
        barView?.dirtyOffsets = dirtyOffsets
    }

    private static func splitLines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    /// Convert hunk-classified diff to current-text UTF-16 line-start anchors: bars mark Added union Modified lines.
    /// Pure deletions have no marker (deletion triangles are intentionally omitted). UTF-16 prefix sums match NSTextStorage coordinates.
    private static func computeOffsets(curText: String, baselineLines: [String]) -> Set<Int> {
        let curLines = splitLines(curText)
        let diff = curLines.difference(from: baselineLines)
        var changed = Set<Int>()     // Current Added/Modified line numbers.
        if !diff.isEmpty {
            var removeOffsets: [Int] = [], insertOffsets: [Int] = []
            for change in diff {
                switch change {
                case let .remove(o, _, _): removeOffsets.append(o)
                case let .insert(o, _, _): insertOffsets.append(o)
                }
            }
            let delRuns = collapseRuns(removeOffsets)
            let insRuns = collapseRuns(insertOffsets)
            var di = 0, ii = 0, delta = 0
            while di < delRuns.count || ii < insRuns.count {
                let d = di < delRuns.count ? delRuns[di] : nil
                let i = ii < insRuns.count ? insRuns[ii] : nil
                if let d, let i, i.start <= d.start + delta {
                    if i.start == d.start + delta {                      // Modified
                        for ln in i.start ..< (i.start + i.len) { changed.insert(ln) }
                        delta += i.len - d.len; di += 1; ii += 1
                    } else {                                             // Added lines before a deletion.
                        for ln in i.start ..< (i.start + i.len) { changed.insert(ln) }
                        delta += i.len; ii += 1
                    }
                } else if let d, (i == nil || d.start + delta < i!.start) {  // Deleted-only hunk: advance delta without drawing markers.
                    delta -= d.len; di += 1
                } else if let i {                                        // Trailing Added lines.
                    for ln in i.start ..< (i.start + i.len) { changed.insert(ln) }
                    delta += i.len; ii += 1
                }
            }
        }
        // Convert line numbers to UTF-16 line-start offsets with prefix sums: starts[k] is the start of line k.
        var starts = [Int](repeating: 0, count: curLines.count + 1)
        for k in 0..<curLines.count { starts[k + 1] = starts[k] + curLines[k].utf16.count + 1 }
        var dirty = Set<Int>()
        for ln in changed where ln >= 0 && ln < curLines.count { dirty.insert(starts[ln]) }
        return dirty
    }

    private static func collapseRuns(_ xs: [Int]) -> [(start: Int, len: Int)] {
        var out: [(start: Int, len: Int)] = []
        for x in xs.sorted() {
            if let last = out.last, x == last.start + last.len { out[out.count - 1].len += 1 }
            else { out.append((x, 1)) }
        }
        return out
    }

    // MARK: Character-level hover highlighting
    /// Compute changed character spans against the baseline from the current TextView when ChangeBarView is hovered,
    /// so highlights stay current and aligned. Hover is infrequent; compute once on entering a hunk.
    /// Return current line numbers mapped to document-level UTF-16 changed spans, suitable for NSTextStorage/rectsFor.
    func charRangesForHover() -> [Int: [NSRange]] {
        guard baselineEstablished, let s = controller?.textView?.string else { return [:] }
        return Self.computeCharRanges(curText: s, baselineLines: baselineLines)
    }

    /// For Modified lines, compare with paired baseline lines using common prefixes/suffixes
    /// (read -> readAAA highlights only AAA). Added lines use the whole line; deletion-only shorter lines also use the whole line.
    private static func computeCharRanges(curText: String, baselineLines: [String]) -> [Int: [NSRange]] {
        let curLines = splitLines(curText)
        let diff = curLines.difference(from: baselineLines)
        var partner: [Int: String] = [:]   // Modified: map current line numbers to paired baseline line content.
        var added = Set<Int>()             // Added: whole new lines without baseline counterparts.
        if !diff.isEmpty {
            var removeOffsets: [Int] = [], insertOffsets: [Int] = []
            for change in diff {
                switch change {
                case let .remove(o, _, _): removeOffsets.append(o)
                case let .insert(o, _, _): insertOffsets.append(o)
                }
            }
            let delRuns = collapseRuns(removeOffsets)
            let insRuns = collapseRuns(insertOffsets)
            var di = 0, ii = 0, delta = 0
            while di < delRuns.count || ii < insRuns.count {
                let d = di < delRuns.count ? delRuns[di] : nil
                let i = ii < insRuns.count ? insRuns[ii] : nil
                if let d, let i, i.start <= d.start + delta {
                    if i.start == d.start + delta {                  // Modified: pair lines individually.
                        for k in 0 ..< i.len {
                            let curLn = i.start + k
                            let baseLn = d.start + k
                            if k < d.len && baseLn >= 0 && baseLn < baselineLines.count {
                                partner[curLn] = baselineLines[baseLn]
                            } else {
                                added.insert(curLn)                  // Extra current lines beyond the baseline are Added.
                            }
                        }
                        delta += i.len - d.len; di += 1; ii += 1
                    } else {                                         // Added lines before a deletion.
                        for k in 0 ..< i.len { added.insert(i.start + k) }
                        delta += i.len; ii += 1
                    }
                } else if let d, (i == nil || d.start + delta < i!.start) {  // Do not mark pure deletions.
                    delta -= d.len; di += 1
                } else if let i {                                    // Trailing Added lines.
                    for k in 0 ..< i.len { added.insert(i.start + k) }
                    delta += i.len; ii += 1
                }
            }
        }
        // Convert line numbers to document UTF-16 line starts with prefix sums, matching computeOffsets coordinates.
        var starts = [Int](repeating: 0, count: curLines.count + 1)
        for k in 0..<curLines.count { starts[k + 1] = starts[k] + curLines[k].utf16.count + 1 }
        var out: [Int: [NSRange]] = [:]
        func emit(_ ln: Int, base: String) {
            guard ln >= 0 && ln < curLines.count else { return }
            let r = changedRange(cur: curLines[ln], base: base, lineStart: starts[ln])
            if !r.isEmpty { out[ln] = r }
        }
        for (ln, base) in partner { emit(ln, base: base) }
        for ln in added { emit(ln, base: "") }
        return out
    }

    /// Use common inline prefix/suffix differences to produce document-level UTF-16 changed spans.
    /// For added lines pass base="" to highlight the whole line. Pure deletions and very long lines also use the whole line to limit work.
    private static func changedRange(cur: String, base: String, lineStart: Int) -> [NSRange] {
        let c = Array(cur.utf16), b = Array(base.utf16)
        if c.isEmpty { return [] }                                  // An empty current line has no highlightable area.
        if c.count > 4000 { return [NSRange(location: lineStart, length: c.count)] }
        let maxMatch = min(c.count, b.count)
        var p = 0
        while p < maxMatch && c[p] == b[p] { p += 1 }
        var s = 0
        while s < (maxMatch - p) && c[c.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let start = p, end = c.count - s
        if end <= start { return [NSRange(location: lineStart, length: c.count)] }  // For a pure deletion, highlight the whole line.
        return [NSRange(location: lineStart + start, length: end - start)]
    }

    private func install() {
        guard let controller, let scrollView = controller.scrollView, controller.textView != nil else { return }
        barView?.removeFromSuperview()
        let v = ChangeBarView()
        v.controller = controller
        v.dirtyOffsets = dirtyOffsets
        v.onResize = { [weak self] in self?.updateFrame() }   // Expand/narrow on hover.
        v.charRanges = { [weak self] in self?.charRangesForHover() ?? [:] }   // Provider for character-level hover highlights.
        // Add after the gutter for higher z-order; use the same .horizontal placement so horizontal scroll stays fixed while vertical scroll follows content.
        scrollView.addFloatingSubview(v, for: .horizontal)
        barView = v
        updateFrame()

        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        scrollView.contentView.postsFrameChangedNotifications = true
        let tv = controller.textView
        let clip = scrollView.contentView
        // Reposition on textView/document size changes and viewport resizing.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tv, queue: .main) { [weak self] _ in self?.updateFrame() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.updateFrame() })
    }

    /// Match document height and textView's y-origin. Width is a narrow strip normally and the full viewport on hover (ChangeBarView.desiredWidth).
    private func updateFrame() {
        guard let controller, let v = barView,
              let tv = controller.textView, let sv = controller.scrollView else { return }
        v.frame = NSRect(x: 0,
                         y: tv.frame.origin.y - sv.contentInsets.top,
                         width: v.desiredWidth(viewport: sv.contentSize.width),
                         height: tv.frame.height + 10)
        v.needsDisplay = true
    }

    func destroy() {
        recomputeWork?.cancel()
        controller?.textView?.removeStorageDelegate(self)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        barView?.removeFromSuperview()
        barView = nil
    }
}

/// Each contiguous unsaved-change hunk appears as a vertical rounded blue capsule,
/// with a light interior and thin darker border. Hover adds a pale-blue hunk-wide background and slightly expands the capsule,
/// plus a separate character-level highlight layer with selection-style fill only over changed text,
/// computed from common prefixes/suffixes (read -> readAAA covers AAA). This layer does not change the background/capsule logic.
/// Only the left stripWidth receives events; the rest passes clicks through to gutter folding and text selection.
private final class ChangeBarView: NSView {
    weak var controller: TextViewController?
    /// Map changed line-start UTF-16 anchors to current line positions with textLineForOffset at draw time, preventing misalignment.
    var dirtyOffsets: Set<Int> = [] {
        didSet { if dirtyOffsets != oldValue { needsDisplay = true } }
    }
    private let barColor = NSColor(hex: 0x1E90FF)
    private let stripWidth: CGFloat = 14          // Leftmost hover-sensitive strip.
    private let capsuleX: CGFloat = 10             // Capsule left edge.
    private let restingW: CGFloat = 5             // Resting capsule width.
    private let hoverW: CGFloat = 7               // Expanded capsule width.
    /// Normally keep the overlay confined to the gutter so NSScrollView can reuse fast copied content without full-width redraws each frame.
    /// Expand to the full viewport through onResize only while hovering to draw the horizontal background.
    private var narrowWidth: CGFloat { capsuleX + hoverW + 6 }
    var onResize: (() -> Void)?
    func desiredWidth(viewport: CGFloat) -> CGFloat { animHunk != nil ? viewport : narrowWidth }

    /// On hover, obtain current changed-character document UTF-16 spans from the coordinator.
    var charRanges: (() -> [Int: [NSRange]])?
    /// Changed-character spans for the hovered hunk in document coordinates; fetched once on entering it.
    private var hoverRanges: [NSRange] = []

    private var hoveredHunk: Int? {               // Currently hovered hunk from the pointer.
        didSet {
            guard hoveredHunk != oldValue else { return }
            if let h = hoveredHunk {
                let hs = hunks()
                let lines = h < hs.count ? hs[h].lines : []
                let map = charRanges?() ?? [:]
                hoverRanges = lines.flatMap { map[$0] ?? [] }   // Fetch current changed-character spans on hunk entry.
                animHunk = h
                onResize?()                       // Expand to full width to draw character highlights.
                animate(to: 1)                    // Expand.
            } else {
                animate(to: 0) { [weak self] in
                    self?.animHunk = nil
                    self?.hoverRanges = []
                    self?.onResize?()             // Retract to the narrow strip.
                    self?.needsDisplay = true
                }
            }
        }
    }
    private var animHunk: Int?                     // Hunk being animated; retain it during collapse so it remains drawable.
    private var hoverProgress: CGFloat = 0 {       // 0 = resting, 1 = fully expanded (capsule widens and background fades in).
        didSet { needsDisplay = true }
    }
    private var anim: Timer?

    override var isFlipped: Bool { true }

    /// Animate hoverProgress toward target (0/1) with smoothstep in .common mode so animation continues during scrolling/dragging.
    private func animate(to target: CGFloat, completion: (() -> Void)? = nil) {
        anim?.invalidate()
        if hoverProgress == target { completion?(); return }
        let start = hoverProgress
        let begin = ProcessInfo.processInfo.systemUptime
        let duration = 0.16
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let raw = min(1.0, (ProcessInfo.processInfo.systemUptime - begin) / duration)
            let eased = CGFloat(raw * raw * (3 - 2 * raw))
            self.hoverProgress = start + (target - start) * eased
            if raw >= 1 { self.hoverProgress = target; t.invalidate(); completion?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        anim = timer
    }

    /// Only the leftmost narrow strip receives hover/click events; all other regions pass through to the gutter/text.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x <= stripWidth else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .inVisibleRect keeps tracking equal to the visible area. bounds.height previously could be zero before frame assignment,
        // leaving an empty tracking area and preventing hover entirely.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInActiveApp],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { updateHovered(event) }
    override func mouseMoved(with event: NSEvent) { updateHovered(event) }
    override func mouseExited(with event: NSEvent) { hoveredHunk = nil }

    /// Highlight a hunk only when the pointer lies in stripWidth and within that hunk's vertical range.
    private func updateHovered(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x <= stripWidth else { hoveredHunk = nil; return }
        hoveredHunk = hunks().firstIndex { p.y >= $0.top && p.y <= $0.bottom }
    }

    /// Vertical extent of each contiguous hunk, in document/textView coordinates.
    /// Map offset anchors to current textLineForOffset positions, sort by line number, and merge adjacent lines into hunks.
    private func hunks() -> [(top: CGFloat, bottom: CGFloat, lines: [Int])] {
        guard let lm = controller?.textView?.layoutManager else { return [] }
        var byIndex: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
        for off in dirtyOffsets {
            guard let pos = lm.textLineForOffset(off) else { continue }
            byIndex[pos.index] = (pos.yPos, pos.yPos + pos.height)
        }
        var result: [(top: CGFloat, bottom: CGFloat, lines: [Int])] = []
        var have = false, prevIdx = -2
        var top: CGFloat = 0, bottom: CGFloat = 0
        var lines: [Int] = []
        for idx in byIndex.keys.sorted() {
            let info = byIndex[idx]!
            if have && idx == prevIdx + 1 {
                top = min(top, info.top); bottom = max(bottom, info.bottom); lines.append(idx)
            } else {
                if have { result.append((top, bottom, lines)) }
                top = info.top; bottom = info.bottom; have = true; lines = [idx]
            }
            prevIdx = idx
        }
        if have { result.append((top, bottom, lines)) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !dirtyOffsets.isEmpty else { return }
        let centerX = capsuleX + restingW / 2       // Expand symmetrically around the resting center.

        for (i, hunk) in hunks().enumerated() {
            let h = hunk.bottom - hunk.top
            let p = (i == animHunk) ? hoverProgress : 0     // Use animation progress only for the animated hunk.
            let w = restingW + (hoverW - restingW) * p
            let cap = NSRect(x: centerX - w / 2, y: hunk.top, width: w, height: h)

            // Hover background joins seamlessly to the capsule with matching corner radii.
            // Draw the rounded background from the capsule's left edge using the same radius, then overlay the capsule at that end;
            // the pale-blue fill is exposed from the right edge while sharing the rounded left side.
            if p > 0.01 {
                let band = NSRect(x: cap.minX, y: hunk.top, width: max(0, bounds.width - cap.minX), height: h)
                let bp = NSBezierPath(roundedRect: band, xRadius: w / 2, yRadius: w / 2)
                barColor.withAlphaComponent(0.09 * p).setFill(); bp.fill()
                barColor.withAlphaComponent(0.40 * p).setStroke(); bp.lineWidth = 1; bp.stroke()
            }

            // An independent character-highlight layer sits above the whole-line background and capsule,
            // using plain selection-style fill without borders/rounding on genuinely changed text spans.
            // The coordinator derives these spans from common prefixes/suffixes (read -> readAAA highlights AAA).
            // rectsFor returns textView-coordinate rectangles; convert them into overlay coordinates before drawing.
            if p > 0.01, let tv = controller?.textView, let lm = tv.layoutManager {
                // Clamp ranges: hover spans may become stale during animation after background diff updates or edits that shorten the text.
                // Passing stale spans to rectsFor can cause an NSRangeException in rangeOfComposedCharacterSequence,
                // seen as a hang/crash when using the diff capsule after pasting long emoji-containing text. Intersect with the current document range first.
                let doc = tv.documentRange
                barColor.withAlphaComponent(0.30 * p).setFill()
                for r in hoverRanges {
                    let safe = NSIntersectionRange(r, doc)
                    guard safe.length > 0 else { continue }
                    for rect in lm.rectsFor(range: safe) {
                        NSBezierPath(rect: convert(rect, from: tv)).fill()
                    }
                }
            }

            // Draw the rounded capsule over the background's left end; expansion changes only width, preserving its resting fill and border.
            guard i == animHunk || cap.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: cap, xRadius: w / 2, yRadius: w / 2)
            barColor.withAlphaComponent(0.5).setFill()
            path.fill()
            barColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

extension EditorTheme {
    /// Build EditorTheme from ServerDock ThemeColors plus light/dark syntax palettes; all colors are NSColor.
    static func serverdock(colors: ThemeColors, isDark: Bool) -> EditorTheme {
        let fg = NSColor(hex: colors.termFg)
        let bg = NSColor(hex: colors.termBg)

        let comment, string, number, keyword, type, function, variable, constant: NSColor
        if isDark {
            comment  = NSColor(hex: 0x6a9955)
            string   = NSColor(hex: 0xce9178)
            number   = NSColor(hex: 0xb5cea8)
            keyword  = NSColor(hex: 0x569cd6)
            type     = NSColor(hex: 0x4ec9b0)
            function = NSColor(hex: 0xdcdcaa)
            variable = NSColor(hex: 0x9cdcfe)
            constant = NSColor(hex: 0x4fc1ff)
        } else {
            comment  = NSColor(hex: 0x008000)
            string   = NSColor(hex: 0xa31515)
            number   = NSColor(hex: 0x098658)
            keyword  = NSColor(hex: 0x0000ff)
            type     = NSColor(hex: 0x267f99)
            function = NSColor(hex: 0x795e26)
            variable = NSColor(hex: 0x001080)
            constant = NSColor(hex: 0x0070c1)
        }

        return EditorTheme(
            text:           Attribute(color: fg),
            insertionPoint: NSColor(hex: colors.termCaret),
            invisibles:     Attribute(color: fg.withAlphaComponent(0.25)),
            background:     bg,
            lineHighlight:  fg.withAlphaComponent(0.06),
            selection:      NSColor(hex: colors.termSelection),
            keywords:       Attribute(color: keyword, bold: true),
            commands:       Attribute(color: function),   // Function-call categories.
            types:          Attribute(color: type),
            attributes:     Attribute(color: variable),
            variables:      Attribute(color: variable),
            values:         Attribute(color: constant),
            numbers:        Attribute(color: number),
            strings:        Attribute(color: string),
            characters:     Attribute(color: string),
            comments:       Attribute(color: comment, italic: true)
        )
    }
}
