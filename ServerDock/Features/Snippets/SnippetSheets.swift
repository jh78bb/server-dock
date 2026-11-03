import SwiftUI

/// Add/edit snippet dialog; non-nil editing enables edit mode and its Delete button.
struct SnippetEditView: View {
    @ObservedObject var model: AppModel
    var editing: Snippet? = nil
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var content = ""
    @State private var group = ""
    @State private var didLoad = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "New Script" : "Edit Script")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled(String(localized: "Name")) { ThemedTextField(placeholder: "e.g. Check disk usage", text: $name) }
                    labeled(String(localized: "Command")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ThemedTextEditor(placeholder: "df -h\nMultiple lines supported. Use {{variable}} placeholders, filled in at runtime.", text: $content)
                            Text("Use {{name}} for placeholders; you'll be prompted to fill them in at runtime.")
                                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        }
                    }
                    labeled(String(localized: "Group")) {
                        VStack(alignment: .leading, spacing: 6) {
                            SearchableSelect(options: model.snippetGroupNames, text: $group,
                                             placeholder: String(localized: "Search or Create Group…"))
                            Text("Collapse into this group in the sidebar (leave empty to use \"Ungrouped\").")
                                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        }
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                if let ed = editing {
                    Button { model.deleteSnippet(ed); dismiss() } label: {
                        Text("Delete").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.red)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                Spacer()
                SecondaryButton(title: "Cancel") { dismiss() }
                PrimaryButton(title: editing == nil ? "Create" : "Save", enabled: canSave) { save() }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480, height: 460)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear(perform: loadOnce)
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        if let ed = editing {
            name = ed.name
            content = ed.content
            group = ed.group
        }
    }

    private func save() {
        let nm = name.trimmingCharacters(in: .whitespaces)
        let grp = group.trimmingCharacters(in: .whitespaces)
        if let ed = editing {
            model.updateSnippet(ed.id, name: nm, content: content, group: grp)
        } else {
            model.addSnippet(name: nm, content: content, group: grp)
        }
        dismiss()
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}
