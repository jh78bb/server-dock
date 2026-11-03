import SwiftUI
import AppKit

private struct TruncWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A truncated single-line value opens a copyable full-text preview on click; untruncated values are not clickable.
/// Used for potentially long single-line messages such as forwarding failures.
struct TruncatableText: View {
    let text: String
    var fontSize: CGFloat = 11
    var color: Color = Pal.red

    @State private var available: CGFloat = 0
    @State private var showPreview = false
    @State private var copied = false

    /// Treat text as truncated when measured full width exceeds available width.
    private var isTruncated: Bool {
        guard available > 0 else { return false }
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return w > available + 1
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .lineLimit(1)
            .background(GeometryReader { g in
                Color.clear.preference(key: TruncWidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(TruncWidthKey.self) { available = $0 }
            .contentShape(Rectangle())
            .onTapGesture { if isTruncated { showPreview = true } }
            .pointerCursor(isTruncated)
            .help(isTruncated ? "Click to view the full content (copyable)" : "")
            .popover(isPresented: $showPreview, arrowEdge: .bottom) { preview }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(lucideSymbol: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        Text(copied ? "Copied" : "Copy").font(.system(size: 12))
                    }
                    .foregroundStyle(copied ? Pal.green : Pal.mauve)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((copied ? Pal.green : Pal.mauve).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(14).frame(width: 380)
    }
}

/// Custom theme-aware segmented control with consistent styling.
struct SegmentedControl<T: Hashable>: View {
    let options: [(value: T, label: Text)]
    @Binding var selection: T
    @ObservedObject private var theme = ThemeManager.shared
    @Namespace private var ns

    // Static UI text uses LocalizedStringKey for automatic String Catalog extraction.
    init(options: [(value: T, label: LocalizedStringKey)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text($0.label)) }
        self._selection = selection
    }
    // Dynamic enum rawValue/title data is verbatim, without localization.
    init(options: [(value: T, verbatim: String)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text(verbatim: $0.verbatim)) }
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let selected = selection == opt.value
                opt.label
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Pal.text : Pal.subtext)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)   // Scale long labels to one line instead of increasing height through wrapping.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.isDark ? Pal.fill(0.14) : Color.white)
                                .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.12), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .pointerCursor()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { selection = opt.value }
                    }
            }
        }
        .padding(3)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Theme-aware field with an accent border while focused.
extension View {
    /// Remove the native macOS blue focus ring; use the shared custom stroke for focus feedback and consistent styling.
    func noNativeFocusRing() -> some View {
        focusEffectDisabled()   // Always available on the minimum supported macOS 14.
    }
}

extension Binding where Value == String {
    /// Single-line proxy binding strips newline/carriage-return characters immediately on paste,
    /// preventing password/name fields expanding vertically. Do not use for multiline ThemedTextEditor.
    var singleLine: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0.filter { !$0.isNewline } })
    }
}

struct ThemedTextField: View {
    private let prompt: Text
    @Binding var text: String
    var autofocus: Bool = false
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @ObservedObject private var theme = ThemeManager.shared

    // Static UI text uses LocalizedStringKey for automatic String Catalog extraction.
    init(placeholder: LocalizedStringKey, text: Binding<String>, autofocus: Bool = false, onSubmit: (() -> Void)? = nil) {
        self.prompt = Text(placeholder); self._text = text; self.autofocus = autofocus; self.onSubmit = onSubmit
    }
    // Dynamic data such as snippet variable names is verbatim, without localization.
    init(verbatim placeholder: String, text: Binding<String>, autofocus: Bool = false, onSubmit: (() -> Void)? = nil) {
        self.prompt = Text(verbatim: placeholder); self._text = text; self.autofocus = autofocus; self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(text: $text.singleLine, prompt: prompt) { EmptyView() }
            .textFieldStyle(.plain)
            .lineLimit(1)
            .noNativeFocusRing()
            .font(.system(size: 13))
            .foregroundStyle(Pal.text)
            .focused($focused)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? Pal.mauve : Pal.fill(0.12), lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: focused)
            .onAppear { if autofocus { focused = true } }
    }
}

/// Multiline text field.
struct ThemedTextEditor: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var autofocus: Bool = false
    /// Return sends through this closure and Shift-Return inserts a newline; IME composition Return only confirms composition.
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @State private var submitFocused = false
    @ObservedObject private var theme = ThemeManager.shared

    private var isFocused: Bool { focused || submitFocused }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Pal.overlay)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            Group {
                if let onSubmit {
                    SubmitTextEditor(text: $text, autofocus: autofocus, textColor: NSColor(Pal.text),
                                     onFocusChange: { submitFocused = $0 }, onSubmit: onSubmit)
                } else {
                    TextEditor(text: $text)
                        .focused($focused)
                }
            }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Pal.text)
                .noNativeFocusRing()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .frame(height: 80)
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Pal.mauve : Pal.fill(0.12), lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .onAppear { if autofocus, onSubmit == nil { focused = true } }
    }
}

/// Handle Return in the actual NSTextView before SwiftUI TextEditor consumes it.
private struct SubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    let autofocus: Bool
    let textColor: NSColor
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = SubmitTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        scroll.documentView = editor
        if autofocus {
            DispatchQueue.main.async { [weak editor] in editor?.window?.makeFirstResponder(editor) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? SubmitTextView else { return }
        editor.textColor = textColor
        editor.insertionPointColor = textColor
        editor.onSubmit = onSubmit
        editor.onFocusChange = onFocusChange
        if editor.string != text { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmitTextEditor
        init(_ parent: SubmitTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.shift, .option]).isEmpty,
           !hasMarkedText(), let onSubmit {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

/// Password field with a show/hide eye button.
struct ThemedSecureField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @State private var reveal = false
    @FocusState private var focusedField: Field?
    @ObservedObject private var theme = ThemeManager.shared

    private enum Field { case secure, plain }
    private var isFocused: Bool { focusedField != nil }

    var body: some View {
        HStack(spacing: 6) {
            // Keep both fields mounted and toggle opacity only, preserving focus when showing/hiding the password.
            ZStack {
                SecureField(placeholder, text: $text.singleLine)
                    .focused($focusedField, equals: .secure)
                    .opacity(reveal ? 0 : 1)
                    .allowsHitTesting(!reveal)
                TextField(placeholder, text: $text.singleLine)
                    .focused($focusedField, equals: .plain)
                    .opacity(reveal ? 1 : 0)
                    .allowsHitTesting(reveal)
            }
            .textFieldStyle(.plain)
            .lineLimit(1)
            .noNativeFocusRing()
            .font(.system(size: 13))
            .foregroundStyle(Pal.text)

            Button {
                let wasFocused = isFocused
                reveal.toggle()
                // Move focus to the visible field; both remain mounted, making focus changes reliable.
                if wasFocused {
                    DispatchQueue.main.async { focusedField = reveal ? .plain : .secure }
                }
            } label: {
                Image(lucideSymbol: reveal ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(isFocused ? Pal.subtext : Pal.overlay)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(reveal ? "Hide Password" : "Show Password")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Pal.mauve : Pal.fill(0.12), lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// Theme-aware custom popover dropdown.
struct ThemedDropdown<T: Hashable>: View {
    let options: [(value: T, label: Text)]
    @Binding var selection: T
    @State private var open = false
    @ObservedObject private var theme = ThemeManager.shared

    // Static UI text uses LocalizedStringKey for automatic String Catalog extraction.
    init(options: [(value: T, label: LocalizedStringKey)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text($0.label)) }
        self._selection = selection
    }
    // Dynamic encoding/algorithm/enum rawValue data is verbatim, without localization.
    init(options: [(value: T, verbatim: String)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text(verbatim: $0.verbatim)) }
        self._selection = selection
    }

    private var currentLabel: Text {
        options.first(where: { $0.value == selection })?.label ?? Text(verbatim: "")
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                currentLabel
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)   // Shrink long English labels to fit one line instead of wrapping and increasing height.
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(lucideSymbol: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.overlay)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(open ? Pal.mauve : Pal.fill(0.12), lineWidth: open ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.12), value: open)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 1) {
                ForEach(options, id: \.value) { opt in
                    DropdownOption(
                        text: opt.label,
                        selected: opt.value == selection
                    ) {
                        selection = opt.value
                        open = false
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 180)
            .background(Pal.solidMantle)
        }
    }
}

private struct DropdownOption: View {
    let label: Text
    let selected: Bool
    var leadingSymbol: String? = nil      // Non-nil adds a small accent icon before the label, such as plus for Create.
    let action: () -> Void
    @State private var hover = false

    // Static UI text uses LocalizedStringKey for automatic String Catalog extraction.
    init(label: LocalizedStringKey, selected: Bool, leadingSymbol: String? = nil, action: @escaping () -> Void) {
        self.label = Text(label); self.selected = selected; self.leadingSymbol = leadingSymbol; self.action = action
    }
    // Dynamic group names/user input are verbatim, without localization.
    init(verbatim label: String, selected: Bool, leadingSymbol: String? = nil, action: @escaping () -> Void) {
        self.label = Text(verbatim: label); self.selected = selected; self.leadingSymbol = leadingSymbol; self.action = action
    }
    // Pass through Text already constructed by the upstream ThemedDropdown.
    init(text label: Text, selected: Bool, leadingSymbol: String? = nil, action: @escaping () -> Void) {
        self.label = label; self.selected = selected; self.leadingSymbol = leadingSymbol; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingSymbol {
                    Image(lucideSymbol: leadingSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.mauve)
                }
                label
                    .font(.system(size: 13))
                    .foregroundStyle(leadingSymbol != nil ? Pal.mauve : (selected ? Pal.mauve : Pal.text))
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(lucideSymbol: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.mauve)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hover ? Pal.fill(0.08) : (selected ? Pal.mauve.opacity(0.10) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
    }
}

/// Searchable custom combobox: filter immediately using the popover's top search field,
/// and offer Create for values absent from existing items. Bind the final value as a string,
/// allowing existing selection or new text, styled consistently with [[ThemedDropdown]].
/// Used for server/RDP/snippet grouping; horizontal chips become crowded with many groups.
struct SearchableSelect: View {
    let options: [String]
    @Binding var text: String
    var placeholder: String = String(localized: "Search or enter a new group…")
    var emptyLabel: String = String(localized: "Ungrouped")      // Placeholder shown when text is empty.
    var allowsCreate: Bool = true

    @State private var open = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var theme = ThemeManager.shared

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var filtered: [String] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.lowercased().contains(q) }
    }

    private var canCreate: Bool {
        allowsCreate && !trimmedQuery.isEmpty
            && !options.contains { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
    }

    var body: some View {
        Button { toggle() } label: {
            HStack(spacing: 8) {
                Text(text.isEmpty ? emptyLabel : text)
                    .font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? Pal.overlay : Pal.text)
                    .lineLimit(1)
                Spacer()
                Image(lucideSymbol: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.overlay)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(open ? Pal.mauve : Pal.fill(0.12), lineWidth: open ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.12), value: open)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(lucideSymbol: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    TextField(placeholder, text: $query.singleLine)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(1)
                        .noNativeFocusRing()
                        .focused($searchFocused)
                        .onSubmit { commitQuery() }
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(theme.isDark ? Pal.fill(0.06) : Color.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.fill(0.12), lineWidth: 1))

                ScrollView {
                    VStack(spacing: 1) {
                        if canCreate {
                            DropdownOption(verbatim: String(localized: "Create \"\(trimmedQuery)\""), selected: false, leadingSymbol: "plus") {
                                select(trimmedQuery)
                            }
                        }
                        ForEach(filtered, id: \.self) { opt in
                            // Click the selected item again to clear to Ungrouped; click another item to change selection.
                            DropdownOption(verbatim: opt, selected: opt == text) {
                                if opt == text { deselect() } else { select(opt) }
                            }
                        }
                        if filtered.isEmpty && !canCreate {
                            Text("No Matches").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(8)
            .frame(width: 240)
            .background(Pal.solidMantle)
        }
    }

    private func toggle() {
        open.toggle()
        if open { query = ""; DispatchQueue.main.async { searchFocused = true } }
    }

    private func select(_ v: String) { text = v; open = false }

    /// Clear selection to Ungrouped and dismiss.
    private func deselect() { text = ""; open = false }

    /// Enter selects an exact existing match or creates a new value when allowed.
    private func commitQuery() {
        if let exact = options.first(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
            select(exact)
        } else if canCreate {
            select(trimmedQuery)
        }
    }
}

/// Place in a sheet background to prevent automatic initial focus on the first text field.
/// Before the window becomes key, set initialFirstResponder to a placeholder that refuses focus,
/// so AppKit's automatic first-field selection fails cleanly without focus-then-blur flicker.
/// User clicks still focus fields normally; only initial automatic focus is prevented.
struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusSink() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FocusSink: NSView {
        override var acceptsFirstResponder: Bool { false }
        // Set initialFirstResponder immediately when attaching to the window, before it becomes key and autofocus runs.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
        }
    }
}

/// Custom increment/decrement stepper.
struct ThemedStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...100
    var step: Int = 1
    var suffix: String = ""
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus") {
                value = max(range.lowerBound, value - step)
            }
            Divider().frame(height: 16).overlay(Pal.fill(0.10))
            Text("\(value)\(suffix)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Pal.text)
                .frame(minWidth: 46)
            Divider().frame(height: 16).overlay(Pal.fill(0.10))
            stepButton("plus") {
                value = min(range.upperBound, value + step)
            }
        }
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.12), lineWidth: 1))
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Pal.subtext)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Custom toggle.
struct ThemedToggle: View {
    @Binding var isOn: Bool
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Pal.mauve : Pal.fill(0.18))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Custom checkbox matching ThemedToggle: mauve fill/white check when selected, empty outline otherwise.
struct ThemedCheckbox: View {
    let isOn: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { action() }
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? Pal.mauve : Pal.fill(0.10))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(isOn ? Color.clear : Pal.fill(0.22), lineWidth: 1))
                .overlay(Image(lucideSymbol: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Centered confirmation dialog with a translucent overlay, replacing system modals.
struct ConfirmDialog: View {
    private let title: Text
    private let message: Text
    var confirmTitle: LocalizedStringKey = "Confirm"
    var cancelTitle: LocalizedStringKey = "Cancel"
    var destructive: Bool = false
    var showCancel: Bool = true   // Set false for informational notices with only a confirmation button.
    var busy: Bool = false         // While confirming, show a spinner and disable confirmation; Cancel remains available to interrupt.
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    // Static title/message use LocalizedStringKey for automatic String Catalog extraction.
    init(title: LocalizedStringKey, message: LocalizedStringKey,
         confirmTitle: LocalizedStringKey = "Confirm", cancelTitle: LocalizedStringKey = "Cancel",
         destructive: Bool = false, showCancel: Bool = true, busy: Bool = false,
         onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.title = Text(title); self.message = Text(message)
        self.confirmTitle = confirmTitle; self.cancelTitle = cancelTitle
        self.destructive = destructive; self.showCancel = showCancel; self.busy = busy
        self.onConfirm = onConfirm; self.onCancel = onCancel
    }
    // Runtime title/message values such as tab names/counts use verbatim, without localization.
    init(verbatimTitle title: String, verbatimMessage message: String,
         confirmTitle: LocalizedStringKey = "Confirm", cancelTitle: LocalizedStringKey = "Cancel",
         destructive: Bool = false, showCancel: Bool = true, busy: Bool = false,
         onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.title = Text(verbatim: title); self.message = Text(verbatim: message)
        self.confirmTitle = confirmTitle; self.cancelTitle = cancelTitle
        self.destructive = destructive; self.showCancel = showCancel; self.busy = busy
        self.onConfirm = onConfirm; self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                title
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                message
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    if showCancel { SecondaryButton(title: cancelTitle, action: onCancel) }
                    if busy { ProgressView().controlSize(.small) }   // Show a spinner beside confirmation while processing.
                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background((destructive ? Pal.red : Pal.mauve).opacity(busy ? 0.6 : 1),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .pointerCursor(!busy)
                }
            }
            .padding(20)
            .frame(width: 340)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }
}

/// Primary accent-filled action button.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var enabled: Bool = true
    var tint: Color? = nil          // Optional server accent for related dialogs; default is the app accent.
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background((tint ?? Pal.mauve).opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointerCursor(enabled)
    }
}

/// Secondary action button.
struct SecondaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Pal.subtext)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}


/// Host-color picker combines preset swatches with ColorPicker.
struct HostColorPicker: View {
    @Binding var hex: String

    private var custom: Binding<Color> {
        Binding(get: { HostPalette.color(hex: hex) ?? Pal.mauve },
                set: { hex = HostPalette.hex(from: $0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HostPalette.presets, id: \.self) { preset in
                let selected = hex.uppercased() == preset
                Button { hex = preset } label: {
                    Circle().fill(HostPalette.color(hex: preset) ?? .gray)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Pal.text, lineWidth: selected ? 2 : 0).padding(-3))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            ColorPicker("", selection: custom, supportsOpacity: false)
                .labelsHidden()
                .help(String(localized: "Custom Color"))
        }
    }
}
