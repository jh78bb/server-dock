import SwiftUI
import AppKit

/// Images tab: list, pull, remove, prune, and create containers.
struct DockerImagesPane: View {
    @ObservedObject var session: DockerSession
    @Binding var runSpecRequest: RunSpec?
    @ObservedObject private var theme = ThemeManager.shared

    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var showPull = false
    @State private var pullRef = ""
    @State private var pendingRemove: [DockerImage]?
    @State private var pendingPrune = false
    @State private var force = false

    private var visible: [DockerImage] {
        let q = query.lowercased()
        return session.images.filter { q.isEmpty || $0.reference.lowercased().contains(q) || $0.id.hasPrefix(q) }
    }
    private var selected: [DockerImage] { session.images.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    TextField(String(localized: "Search images…"), text: $query).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 200)
                }
                .padding(.horizontal, 8).padding(.vertical, 5).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                Text("\(session.images.count) images").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                if session.imageBusy { ProgressView().controlSize(.small) }
                Spacer()
                button("arrow.down.circle", String(localized: "Pull an image…"), false) { pullRef = ""; showPull = true }
                button("play.circle", String(localized: "Run a container from this image…"), selected.count != 1) {
                    if let i = selected.first { runSpecRequest = RunSpec(image: i.reference) }
                }
                button("sparkles", String(localized: "Remove unused (dangling) images"), false) { pendingPrune = true }
                button("trash", String(localized: "Remove"), selected.isEmpty) { pendingRemove = selected }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Table(visible, selection: $selection) {
                TableColumn("Image") { i in
                    HStack(spacing: 6) {
                        Image(lucideSymbol: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(i.isDangling ? Pal.overlay : Pal.tint)
                        Text(verbatim: i.displayName).lineLimit(1)
                    }
                }.width(min: 160, ideal: 280)
                TableColumn("Tag") { i in Text(verbatim: i.tag).foregroundStyle(Pal.subtext) }.width(min: 60, ideal: 110)
                TableColumn("ID") { i in Text(verbatim: i.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext) }.width(min: 90, ideal: 110)
                TableColumn("Size") { i in Text(verbatim: i.size).foregroundStyle(Pal.subtext) }.width(min: 60, ideal: 90)
                TableColumn("Created") { i in Text(verbatim: i.created).foregroundStyle(Pal.subtext).lineLimit(1) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = session.images.filter { ids.contains($0.id) }
                if items.count == 1, let i = items.first {
                    Button("Run a container from this image…") { runSpecRequest = RunSpec(image: i.reference) }
                    Button("Copy Image Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(i.reference, forType: .string) }
                    Divider()
                }
                if !items.isEmpty { Button("Remove", role: .destructive) { pendingRemove = items } }
            }
            .overlay { if visible.isEmpty { Text("No images").font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false) } }
        }
        .onAppear { session.loadImages() }
        .sheet(isPresented: $showPull) { pullSheet }
        .confirmationDialog(String(localized: "Remove \(pendingRemove?.count ?? 0) image(s)?"), isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let r = pendingRemove { session.removeImages(r, force: false) }; pendingRemove = nil }
            Button("Force Remove", role: .destructive) { if let r = pendingRemove { session.removeImages(r, force: true) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { Text("Images used by a container can't be removed unless you force it. Layers shared with other images are kept.") }
        .confirmationDialog(String(localized: "Remove unused images?"), isPresented: $pendingPrune, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { session.pruneImages() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deletes images without a tag that no container uses (image prune).") }
    }

    private func button(_ symbol: String, _ help: String, _ disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12)).foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext).frame(width: 28, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }

    private var pullSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pull an image").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
            ThemedTextField(verbatim: "nginx:latest", text: $pullRef, autofocus: true) { start() }
            Text("Downloads the image on the server. Large images can take a few minutes.").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            HStack { Spacer(); SecondaryButton(title: "Cancel") { showPull = false }; PrimaryButton(title: "Pull", enabled: !pullRef.trimmingCharacters(in: .whitespaces).isEmpty, tint: Pal.tint) { start() } }
        }
        .padding(20).frame(width: 420).background(Pal.solidBase).preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func start() {
        let r = pullRef.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return }
        showPull = false
        session.pull(r)
    }
}

/// Container run -d form includes image/name/ports/env/volumes/restart/command and previews the command.
struct RunContainerSheet: View {
    let engine: String
    @State var spec: RunSpec
    let onRun: (RunSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(lucideSymbol: "play.circle").foregroundStyle(Pal.tint)
                Text("Run a Container").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }.buttonStyle(.plain).pointerCursor()
            }
            HStack(alignment: .top, spacing: 12) {
                field(String(localized: "Image")) { textField("nginx:latest", $spec.image) }
                field(String(localized: "Name (optional)")) { textField("web", $spec.name) }.frame(width: 190)
            }
            HStack(alignment: .top, spacing: 12) {
                field(String(localized: "Ports (one per line)")) { editor("8080:80", $spec.ports) }
                field(String(localized: "Environment (KEY=value per line)")) { editor("TZ=Asia/Seoul", $spec.env) }
            }
            HStack(alignment: .top, spacing: 12) {
                field(String(localized: "Volumes (one per line)")) { editor("/srv/data:/data", $spec.volumes) }
                VStack(alignment: .leading, spacing: 12) {
                    field(String(localized: "Restart policy")) {
                        SegmentedControl(options: [(value: "no", verbatim: "no"), (value: "always", verbatim: "always"), (value: "unless-stopped", verbatim: "unless-stopped")], selection: $spec.restart)
                    }
                    field(String(localized: "Command (optional)")) { textField("e.g. sleep infinity", $spec.command) }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: "$").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.overlay)
                Text(verbatim: DockerCommands.run(spec, engine: engine)).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Pal.textBright)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(12).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                if let p = spec.problem { Text(p).font(.system(size: 11)).foregroundStyle(Pal.yellow) }
                Spacer()
                SecondaryButton(title: "Cancel") { dismiss() }
                PrimaryButton(title: "Run", enabled: spec.problem == nil, tint: Pal.tint) { onRun(spec); dismiss() }
            }
        }
        .padding(20).frame(width: 640).background(Pal.solidBase).preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11)).foregroundStyle(Pal.overlay); c() }
    }
    private func textField(_ ph: String, _ t: Binding<String>) -> some View {
        TextField(ph, text: t).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
    private func editor(_ ph: String, _ t: Binding<String>) -> some View {
        TextField(ph, text: t, axis: .vertical).lineLimit(3...5).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}
