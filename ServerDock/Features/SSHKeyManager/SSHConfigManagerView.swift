import SwiftUI

/// Config tab lists/details/edits/adds/deletes ~/.ssh/config Host blocks,
/// with reachability dots and the same left-list/right-detail layout as Keys.
struct SSHConfigManagerTabView: View {
    @ObservedObject var model: SSHKeyManagerModel
    @State private var query = ""
    @State private var editingEntry: SSHConfigEntry?
    @State private var addingHost = false
    @State private var deletingEntry: SSHConfigEntry?

    private var filtered: [SSHConfigEntry] {
        guard !query.isEmpty else { return model.configEntries }
        return model.configEntries.filter { SSHConfigEntry.fuzzyMatches(query: query, in: $0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            Divider().overlay(Pal.fill(0.06))
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $addingHost) {
            SSHConfigHostEditorSheet(model: model, entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            SSHConfigHostEditorSheet(model: model, entry: entry)
        }
        .alert(String(localized: "Delete Host?"), isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }
        ), presenting: deletingEntry) { entry in
            Button(String(localized: "Delete"), role: .destructive) { model.deleteConfigHost(entry) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { entry in
            Text("This removes the \"Host \(entry.host)\" block from ~/.ssh/config. This cannot be undone.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                TextField(String(localized: "Search Hosts…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.top, 10)

            if model.configMissing {
                VStack(spacing: 10) {
                    Spacer()
                    Image(lucideSymbol: "doc.badge.plus").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                    Text("No ~/.ssh/config file yet").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    Button(String(localized: "Create")) { model.createEmptyConfigIfMissing() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.tint).pointerCursor()
                    Spacer()
                }
            } else if model.configEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(lucideSymbol: "server.rack").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                    Text("No Host entries yet").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { entry in row(entry) }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
            Button { addingHost = true } label: {
                Label(String(localized: "Add Host"), lucideSymbol: "plus")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Pal.tint, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).pointerCursor()
            .padding(12)
            .disabled(model.configMissing)
            .opacity(model.configMissing ? 0.4 : 1)
        }
    }

    private func row(_ entry: SSHConfigEntry) -> some View {
        let selected = model.selectedConfigEntryID == entry.id
        return Button { model.selectedConfigEntryID = entry.id } label: {
            HStack(spacing: 10) {
                dot(for: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                    Text(entry.hostName).font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? Pal.tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    @ViewBuilder
    private func dot(for entry: SSHConfigEntry) -> some View {
        let status = model.reachability[entry.id]
        Group {
            switch status {
            case .reachable: Circle().fill(Pal.green)
            case .unreachable: Circle().fill(Pal.red)
            case .error, .none: Circle().fill(Pal.overlay.opacity(0.4))
            case .checking: ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 7, height: 7)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selectedConfigEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(lucideSymbol: "server.rack").font(.system(size: 18)).foregroundStyle(Pal.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.host).font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                            reachabilityLabel(entry)
                        }
                        Spacer()
                        actionButton("pencil", String(localized: "Edit")) { editingEntry = entry }
                        actionButton("trash", String(localized: "Delete"), destructive: true) { deletingEntry = entry }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.fields.filter { $0.normalizedName != "host" }) { field in
                            HStack(alignment: .top) {
                                Text(field.name).font(.system(size: 12)).foregroundStyle(Pal.subtext).frame(width: 140, alignment: .leading)
                                Text(field.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.copyConfigField(field.value) } label: {
                                    Image(lucideSymbol: "doc.on.doc").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                                }
                                .buttonStyle(.plain).pointerCursor()
                            }
                        }
                        if entry.fields.filter({ $0.normalizedName != "host" }).isEmpty {
                            Text("No fields in this Host block.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        }
                    }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text(model.configMissing ? "No ~/.ssh/config file yet" : "Select a Host")
                    .font(.system(size: 13)).foregroundStyle(Pal.overlay)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func reachabilityLabel(_ entry: SSHConfigEntry) -> some View {
        switch model.reachability[entry.id] {
        case .reachable: Text("Reachable").font(.system(size: 11)).foregroundStyle(Pal.green)
        case .unreachable: Text("Unreachable").font(.system(size: 11)).foregroundStyle(Pal.red)
        case .error: Text("Couldn't check").font(.system(size: 11)).foregroundStyle(Pal.overlay)
        case .checking: Text("Checking…").font(.system(size: 11)).foregroundStyle(Pal.overlay)
        case .none: Text("Not checked").font(.system(size: 11)).foregroundStyle(Pal.overlay)
        }
    }

    private func actionButton(_ symbol: String, _ label: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12))
                .foregroundStyle(destructive ? Pal.red : Pal.subtext)
                .frame(width: 28, height: 28)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(label)
    }
}

/// Add/edit Host form: alias plus an editable list of arbitrary field-name/value pairs.
private struct SSHConfigHostEditorSheet: View {
    @ObservedObject var model: SSHKeyManagerModel
    let entry: SSHConfigEntry?

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var rows: [SSHConfigHostPropertyValue] = []

    private var isEditing: Bool { entry != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Host" : "Add Host").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Host Alias").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        ThemedTextField(placeholder: "myserver", text: $host, autofocus: !isEditing)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Fields").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            Spacer()
                            Button { rows.append(SSHConfigHostPropertyValue(name: "", value: "")) } label: {
                                Label(String(localized: "Add Field"), lucideSymbol: "plus")
                                    .font(.system(size: 11)).foregroundStyle(Pal.tint)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                        ForEach($rows) { $row in
                            HStack(spacing: 8) {
                                ThemedTextField(placeholder: "HostName", text: $row.name).frame(width: 150)
                                ThemedTextField(placeholder: "value", text: $row.value)
                                Button { rows.removeAll { $0.id == row.id } } label: {
                                    Image(lucideSymbol: "minus.circle").font(.system(size: 13)).foregroundStyle(Pal.red)
                                }
                                .buttonStyle(.plain).pointerCursor()
                            }
                        }
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Button {
                    let request = SSHConfigHostSaveRequest(host: host, properties: rows)
                    if let entry { model.updateConfigHost(entry, with: request) }
                    else { model.addConfigHost(request) }
                    dismiss()
                } label: {
                    Text("Save").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.tint, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(host.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480, height: 480)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            if let entry {
                host = entry.host
                rows = entry.fields.filter { $0.normalizedName != "host" }.map {
                    SSHConfigHostPropertyValue(name: $0.name, value: $0.value)
                }
            } else {
                rows = [SSHConfigHostPropertyValue(name: "HostName", value: ""),
                       SSHConfigHostPropertyValue(name: "User", value: "")]
            }
        }
    }
}
