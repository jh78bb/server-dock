import SwiftUI

/// Right-panel snippets tab provides search/create, collapsible groups, terminal run/insert, and editing.
/// Observe TabsModel so terminal availability updates immediately on tab changes.
struct SnippetsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var collapsedGroups: Set<String> = []   // Applies only to this app run, like host-sidebar state; not persisted across restarts.
    @State private var query = ""

    private var filtered: [Snippet] {
        let q = query.lowercased()
        guard !q.isEmpty else { return model.snippets }
        return model.snippets.filter {
            $0.name.lowercased().contains(q)
                || $0.content.lowercased().contains(q)
                || $0.displayGroup.lowercased().contains(q)
        }
    }

    /// Group names deduplicated in snippet order.
    private var groups: [String] {
        var seen: [String] = []
        for s in filtered where !seen.contains(s.displayGroup) { seen.append(s.displayGroup) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            list
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                TextField(String(localized: "Search Scripts…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.text)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
            Button { model.showCreateSnippet = true } label: {
                Image(lucideSymbol: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.mauve)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().help(String(localized: "New Script"))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder
    private var list: some View {
        if model.snippets.isEmpty {
            emptyState
        } else if filtered.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("No Matching Scripts").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.self) { group in
                        groupHeader(group)
                        if !collapsedGroups.contains(group) {
                            ForEach(filtered.filter { $0.displayGroup == group }) { s in
                                SnippetRow(snippet: s, model: model, canRun: model.hasSnippetTarget)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = collapsedGroups.contains(group)
        return Button {
            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        } label: {
            HStack(spacing: 4) {
                Image(lucideSymbol: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 11)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(group).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(lucideSymbol: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("No scripts yet").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("Save frequent commands as scripts and send them to the terminal with one click").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Button { model.showCreateSnippet = true } label: {
                Text("New Script").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

/// Snippet row supports details/editing, default execution, and run/insert/copy/edit/delete context actions.
private struct SnippetRow: View {
    let snippet: Snippet
    @ObservedObject var model: AppModel
    let canRun: Bool
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var hasVars: Bool { !Snippet.variableNames(in: snippet.content).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12)).foregroundStyle(Pal.mauve).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(snippet.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                    if hasVars {
                        Image(lucideSymbol: "curlybraces").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                            .help(String(localized: "Contains {{variables}} filled in at runtime"))
                    }
                }
                Text(snippet.preview)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover && canRun {
                Button { model.triggerSnippet(snippet) } label: {
                    Image(lucideSymbol: "play.fill").font(.system(size: 11)).foregroundStyle(Pal.mauve)
                        .frame(width: 22, height: 22)
                        .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Use Script"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover ? Pal.fill(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // Single-click opens the script tab for variables/target/run/copy; omit double-click gestures that delay Play-button recognition.
        // Play immediately follows the ask/insert/run preference.
        .onTapGesture { model.openScript(snippet) }
        .contextMenu {
            Button("Run in Current Terminal") { model.sendSnippet(snippet, run: true) }.disabled(!canRun)
            Button("Insert into Current Terminal") { model.sendSnippet(snippet, run: false) }.disabled(!canRun)
            Button("Copy Body") { model.copySnippet(snippet) }
            Button("Edit") { model.editingSnippet = snippet }
            Divider()
            Button("Delete", role: .destructive) { model.deleteSnippet(snippet) }
        }
    }
}
