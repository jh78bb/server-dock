import SwiftUI

/// Sites sidebar groups registered SMB/WebDAV/S3 connections; clicking opens a browser tab.
struct SitesPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var query = ""
    @State private var collapsedGroups: Set<String> = []

    private var filtered: [Site] {
        let q = query.lowercased()
        guard !q.isEmpty else { return model.sites }
        return model.sites.filter {
            $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q) || $0.path.lowercased().contains(q)
                || $0.kind.label.lowercased().contains(q)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for s in filtered where !seen.contains(s.displayGroup) { seen.append(s.displayGroup) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                TextField(String(localized: "Search Storage…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Pal.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)

            if model.sites.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                VStack(spacing: 10) {
                    Spacer().frame(height: 40)
                    Image(lucideSymbol: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                    Text("No Matching Storage").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.self) { group in
                            groupHeader(group)
                            if !collapsedGroups.contains(group) {
                                ForEach(filtered.filter { $0.displayGroup == group }) { site in
                                    SiteRow(site: site, model: model)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: String) -> some View {
        // Omit the header if Ungrouped is the only group.
        if !(groups.count == 1 && group == String(localized: "Ungrouped")) {
            Button {
                if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
            } label: {
                HStack(spacing: 5) {
                    Image(lucideSymbol: collapsedGroups.contains(group) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Pal.overlay).frame(width: 10)
                    Text(group).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                    Spacer()
                }
                .padding(.horizontal, 4).padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(lucideSymbol: "externaldrive.connected.to.line.below").font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("No storage yet").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("Connect to SMB shares, WebDAV servers and S3-compatible storage and browse their files")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay).multilineTextAlignment(.center)
            Button { model.showAddSite = true } label: {
                Text("Add Storage").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16)
    }
}

private struct SiteRow: View {
    let site: Site
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: site.kind.symbol)
                .font(.system(size: 14)).foregroundStyle(Pal.mauve).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                Text(site.subtitle).font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(site.kind.label)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(Pal.subtext)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Pal.fill(0.07), in: Capsule())
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover ? Pal.fill(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.openSite(site) }
        .pointerCursor()
        .contextMenu {
            Button("Open") { model.openSite(site) }
            if FinderMount.supports(site) {
                Button("Mount in Finder") { model.mountSiteInFinder(site) }
            }
            Button("Edit") { model.editingSite = site }
            Button("Duplicate") { model.duplicateSite(site) }
            Divider()
            Button("Delete", role: .destructive) { model.siteBeingDeleted = site }
        }
    }
}
