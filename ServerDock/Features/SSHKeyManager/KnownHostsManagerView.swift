import SwiftUI

/// Known Hosts tab groups read-only known_hosts entries by host, supporting line deletion and fingerprint copy.
/// Do not edit host-key contents; arbitrary changes would compromise MITM protection with little benefit.
struct KnownHostsManagerTabView: View {
    @ObservedObject var model: SSHKeyManagerModel
    @State private var query = ""
    @State private var selectedGroupID: String?
    @State private var deletingEntry: KnownHostEntry?
    @State private var deletingGroup: KnownHostGroup?

    private var filtered: [KnownHostGroup] {
        guard !query.isEmpty else { return model.knownHostGroups }
        let q = query.lowercased()
        return model.knownHostGroups.filter { group in
            group.host.lowercased().contains(q) || group.entries.contains { $0.keyType.lowercased().contains(q) }
        }
    }

    private var selectedGroup: KnownHostGroup? {
        model.knownHostGroups.first { $0.id == selectedGroupID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            Divider().overlay(Pal.fill(0.06))
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(String(localized: "Remove Entry?"), isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }
        ), presenting: deletingEntry) { entry in
            Button(String(localized: "Remove"), role: .destructive) { model.deleteKnownHost(entry) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { entry in
            Text("This removes this line from known_hosts. If the host key is legitimate, the next SSH connection will ask to trust it again.")
        }
        .alert(String(localized: "Delete All Entries?"), isPresented: Binding(
            get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }
        ), presenting: deletingGroup) { group in
            Button(String(localized: "Delete All"), role: .destructive) { model.deleteKnownHostGroup(group) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { group in
            Text("This removes all \(group.entries.count) known_hosts entries for \(group.host). If the host key is legitimate, the next SSH connection will ask to trust it again.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                TextField(String(localized: "Search Known Hosts…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.top, 10)

            if model.knownHostGroups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(lucideSymbol: "checkmark.shield").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                    Text("No known_hosts entries").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { group in row(group) }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ group: KnownHostGroup) -> some View {
        let selected = selectedGroupID == group.id
        return Button { selectedGroupID = group.id } label: {
            HStack(spacing: 10) {
                Image(lucideSymbol: "server.rack").font(.system(size: 12))
                    .foregroundStyle(selected ? Pal.tint : Pal.overlay).frame(width: 18)
                Text(group.host).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.keyCount)").font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? Pal.tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .contextMenu {
            Button(String(localized: "Delete All (\(group.keyCount))"), role: .destructive) { deletingGroup = group }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let group = selectedGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(lucideSymbol: "server.rack").font(.system(size: 18)).foregroundStyle(Pal.tint)
                        Text(group.host).font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                        Spacer()
                        Button { deletingGroup = group } label: {
                            Label(String(localized: "Delete All (\(group.keyCount))"), lucideSymbol: "trash")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.red)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Pal.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                    ForEach(group.entries) { entry in entryCard(entry) }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a host").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryCard(_ entry: KnownHostEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.keyType).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Spacer()
                Button { model.copyKnownHostFingerprint(entry) } label: {
                    Image(lucideSymbol: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Copy Fingerprint"))
                Button { deletingEntry = entry } label: {
                    Image(lucideSymbol: "trash").font(.system(size: 11)).foregroundStyle(Pal.red)
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Remove"))
            }
            Text(entry.fingerprint).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext).textSelection(.enabled)
            if entry.hosts.count > 1 {
                Text(entry.hosts.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Pal.overlay).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
