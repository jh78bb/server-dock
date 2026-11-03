import SwiftUI
import AppKit

/// One Command-K palette item.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let category: String
    var keywords: String = ""
    let action: () -> Void
}

enum PaletteSearch {
    /// Subsequence score prefers consecutive matches, word starts, and earlier positions; nil means no match.
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, streak = 0
        for (i, ch) in t.enumerated() where qi < q.count {
            if ch == q[qi] {
                streak += 1
                score += 10 + streak * 6
                if i == 0 || !t[i - 1].isLetter && !t[i - 1].isNumber { score += 12 }   // Word start.
                if i < 6 { score += 4 }
                qi += 1
            } else { streak = 0 }
        }
        return qi == q.count ? score - t.count / 8 : nil
    }

    /// Every query word must match title/subtitle/keywords; weight title matches higher.
    static func rank(_ query: String, _ items: [PaletteItem]) -> [PaletteItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        var scored: [(PaletteItem, Int)] = []
        for it in items {
            var total = 0, ok = true
            for w in words {
                if let s = score(w, in: it.title) { total += s * 3 }
                else if let s = score(w, in: it.subtitle + " " + it.keywords + " " + it.category) { total += s }
                else { ok = false; break }
            }
            if ok { scored.append((it, total)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension AppModel {
    /// Palette includes tabs, host actions, storage, snippets, and app actions.
    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        let cat = { (s: String) in s }

        // Actions.
        items.append(PaletteItem(id: "act-forwards", title: String(localized: "Port Forwarding"), subtitle: String(localized: "All Servers"), symbol: "arrow.left.arrow.right",
                                 category: cat(String(localized: "Actions")), keywords: "tunnel forwarding 포트 터널") { [weak self] in self?.openAllForwards() })
        items.append(PaletteItem(id: "act-multi", title: String(localized: "Run Command on Multiple Servers…"), subtitle: "", symbol: "rectangle.stack.badge.play",
                                 category: cat(String(localized: "Actions")), keywords: "broadcast batch") { [weak self] in self?.showMultiRun = true })
        items.append(PaletteItem(id: "act-nettools", title: String(localized: "Network Tools…"), subtitle: "DNS · Ping · TCP · Whois · SSL", symbol: "wrench.and.screwdriver",
                                 category: cat(String(localized: "Actions")), keywords: "dns ping tcp port whois ssl subdomain traceroute subnet") { [weak self] in self?.openNetTools(NetToolsRequest()) })
        if AppEnv.localTerminalEnabled {
            items.append(PaletteItem(id: "act-localterm", title: String(localized: "New Local Terminal"), subtitle: "", symbol: "terminal",
                                     category: cat(String(localized: "Actions"))) { [weak self] in self?.openLocalTerminal() })
        }
        items.append(PaletteItem(id: "act-addhost", title: String(localized: "Add Host"), subtitle: "", symbol: "plus.circle",
                                 category: cat(String(localized: "Actions"))) { [weak self] in self?.showAddHost = true })
        items.append(PaletteItem(id: "act-addstorage", title: String(localized: "Add Storage"), subtitle: "", symbol: "externaldrive.badge.plus",
                                 category: cat(String(localized: "Actions"))) { [weak self] in self?.showAddSite = true })
        items.append(PaletteItem(id: "act-sshkeys", title: String(localized: "SSH Key Manager"), subtitle: "", symbol: "key.viewfinder",
                                 category: cat(String(localized: "Actions"))) { [weak self] in self?.openKeyManager() })
        items.append(PaletteItem(id: "act-settings", title: String(localized: "Settings"), subtitle: "", symbol: "gearshape",
                                 category: cat(String(localized: "Actions"))) { [weak self] in self?.showSettings = true })
        if AppLock.shared.enabled {
            items.append(PaletteItem(id: "act-lock", title: String(localized: "Lock ServerDock"), subtitle: "⌃⌘L", symbol: "lock",
                                     category: cat(String(localized: "Actions"))) { AppLock.shared.lock() })
        }
        items.append(PaletteItem(id: "act-privacy", title: privacyMode ? String(localized: "Turn Privacy Mode Off") : String(localized: "Turn Privacy Mode On"),
                                 subtitle: "", symbol: "eye.slash", category: cat(String(localized: "Actions"))) { [weak self] in self?.privacyMode.toggle() })

        // Open tabs.
        for t in tabs {
            let hostName = host(t.hostId)?.name ?? site(forTabKey: t.hostId)?.name ?? (t.kind == .portForwards ? String(localized: "Port Forwarding") : t.kind == .netTools || t.kind == .keyManager ? String(localized: "Tools") : String(localized: "Local"))
            items.append(PaletteItem(id: "tab-\(t.id)", title: t.title, subtitle: hostName, symbol: "rectangle.on.rectangle",
                                     category: String(localized: "Open Tabs")) { [weak self] in self?.selectTab(t.id) })
        }

        // Hosts.
        for h in hosts {
            if h.isRDP {
                items.append(PaletteItem(id: "rdp-\(h.id)", title: h.name, subtitle: String(localized: "Remote Desktop") + " · " + h.ipOrHost, symbol: "display",
                                         category: String(localized: "Hosts"), keywords: "rdp vnc") { [weak self] in self?.openHostRDP(h) })
                continue
            }
            let sub = h.isLocal ? String(localized: "This Mac") : h.addr
            items.append(PaletteItem(id: "term-\(h.id)", title: h.name, subtitle: String(localized: "Connect") + " · " + sub, symbol: "terminal",
                                     category: String(localized: "Hosts"), keywords: "ssh connect terminal") { [weak self] in self?.openHostTerminal(h) })
            let tools: [(String, String, String, () -> Void)] = {
                var t: [(String, String, String, () -> Void)] = [
                    ("overview", String(localized: "Overview"), "square.grid.2x2", { [weak self] in self?.openHost(h) }),
                    ("files", String(localized: "Files"), "folder", { [weak self] in self?.openHostFiles(h) }),
                    ("proc", String(localized: "Processes"), "list.bullet.rectangle", { [weak self] in self?.openProcesses(h) }),
                ]
                if !h.isLocal {
                    t.append(("ai", String(localized: "AI Assistant"), "sparkles", { [weak self] in self?.openHostAIChat(h) }))
                    t.append(("fwd", String(localized: "Port Forwarding"), "arrow.left.arrow.right", { [weak self] in self?.openForwardPanel(h) }))
                    if osKind[h.id] == "Linux" { t.append(("fw", String(localized: "Firewall"), "flame", { [weak self] in self?.firewallRequest = FirewallRequest(host: h) })) }
                    t.append(("ports", String(localized: "Open Ports"), "network", { [weak self] in self?.portsHost = h }))
                    t.append(("nettools", String(localized: "Network Tools"), "wrench.and.screwdriver", { [weak self] in self?.openNetTools(NetToolsRequest(host: h)) }))
                    t.append(("http", String(localized: "HTTP Check"), "waveform.badge.magnifyingglass", { [weak self] in self?.openNetTools(NetToolsRequest(host: h, tool: .http)) }))
                }
                if h.isLocal { t.append(("ports", String(localized: "Open Ports"), "network", { [weak self] in self?.portsHost = h })) }
                if hasDocker(h) { t.append(("docker", "Docker", "shippingbox", { [weak self] in self?.openDocker(h) })) }
                if hasSystemd(h) { t.append(("svc", String(localized: "Services"), "gearshape.2", { [weak self] in self?.openServices(h) })) }
                return t
            }()
            for (key, title, symbol, run) in tools {
                items.append(PaletteItem(id: "\(key)-\(h.id)", title: "\(h.name) › \(title)", subtitle: sub, symbol: symbol,
                                         category: String(localized: "Hosts"), keywords: title, action: run))
            }
        }

        // Storage.
        for s in sites {
            items.append(PaletteItem(id: "site-\(s.id)", title: s.name, subtitle: s.kind.label + " · " + s.subtitle, symbol: s.kind.symbol,
                                     category: String(localized: "Storage")) { [weak self] in self?.openSite(s) })
        }

        // Snippets.
        for sn in snippets {
            items.append(PaletteItem(id: "snip-\(sn.id)", title: sn.name, subtitle: sn.preview, symbol: "chevron.left.forwardslash.chevron.right",
                                     category: String(localized: "Scripts"), keywords: sn.content) { [weak self] in self?.triggerSnippet(sn) })
        }
        return items
    }
}

/// Command-K palette: search/results, arrows navigate, Return runs, Escape dismisses.
struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var query = ""
    @State private var selected = 0
    @State private var items: [PaletteItem] = []
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        let r = PaletteSearch.rank(query, items)
        return Array(r.prefix(40))
    }

    var body: some View {
        let list = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(lucideSymbol: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Pal.overlay)
                    TextField(String(localized: "Search hosts, tabs, scripts and actions…"), text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16)).foregroundStyle(Pal.text)
                        .focused($focused)
                        .onSubmit { run(list) }
                        .onKeyPress(.downArrow) { move(1, count: list.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, count: list.count); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                Divider().overlay(Pal.fill(0.08))
                if list.isEmpty {
                    Text("No results").font(.system(size: 13)).foregroundStyle(Pal.overlay).padding(24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                                    row(item, isSelected: idx == selected, showCategory: idx == 0 || list[idx - 1].category != item.category)
                                        .id(item.id)
                                        .onTapGesture { selected = idx; run(list) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: selected) { i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
                    }
                }
                Divider().overlay(Pal.fill(0.08))
                HStack(spacing: 14) {
                    hint("↑↓", String(localized: "Move")); hint("↩", String(localized: "Open")); hint("esc", String(localized: "Close"))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
            .frame(width: 620)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 90)
        }
        .onAppear { items = model.paletteItems(); selected = 0; DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { _ in selected = 0 }
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, isSelected: Bool, showCategory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showCategory {
                Text(item.category).font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.overlay)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
            }
            HStack(spacing: 10) {
                Image(lucideSymbol: item.symbol).font(.system(size: 13)).foregroundStyle(isSelected ? Pal.tint : Pal.subtext).frame(width: 20)
                Text(verbatim: item.title).font(.system(size: 13.5)).foregroundStyle(Pal.text).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(verbatim: item.subtitle).font(.system(size: 11.5)).foregroundStyle(Pal.overlay).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isSelected ? Pal.tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Pal.subtext)
                .padding(.horizontal, 5).padding(.vertical, 1).background(Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10.5)).foregroundStyle(Pal.overlay)
        }
    }

    private func move(_ d: Int, count: Int) {
        guard count > 0 else { return }
        selected = (selected + d + count) % count
    }

    private func run(_ list: [PaletteItem]) {
        guard list.indices.contains(selected) else { return }
        let item = list[selected]
        close()
        DispatchQueue.main.async { item.action() }   // Execute after dismissal to avoid overlapping sheet/tab transitions.
    }

    private func close() { model.showPalette = false }
}
