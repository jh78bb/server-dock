import SwiftUI

/// Server log-file picker follows the AI path-picker interaction.
/// Enter folders, tick files, or type a path to navigate folders/add files.
struct LogFilePicker: View {
    let fs: RemoteFS
    let alreadyAdded: Set<String>
    let onAdd: ([String]) -> Void

    @State private var path = ""
    @State private var input = ""
    @State private var entries: [RemoteFile] = []
    @State private var loading = true
    @State private var error: String?
    @State private var checked: [String] = []          // Preserve selection order.
    @State private var typedFile: String?              // Typed path is not a directory and can be added as a file.
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose log files").font(.system(size: 14, weight: .bold)).foregroundStyle(Pal.text)
            Text("Open a folder and tick the files to add, or type a path and press Return.")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                iconButton("arrow.up", help: String(localized: "Parent folder")) { go((path as NSString).deletingLastPathComponent) }
                    .disabled(path == "/" || path.isEmpty)
                iconButton("house", help: String(localized: "Home folder")) { Task { go(await fs.home()) } }
                iconButton("doc.text", help: String(localized: "/var/log")) { go("/var/log") }
                TextField("/var/log/…", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .focused($inputFocused)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(inputFocused ? Pal.tint : Color.clear, lineWidth: 1))
                    .onSubmit { submitTyped() }
            }

            if let f = typedFile {
                HStack(spacing: 8) {
                    Image(lucideSymbol: "doc.text").foregroundStyle(Pal.subtext)
                    Text(verbatim: f).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                    Button { toggle(f) } label: {
                        Text(checked.contains(f) ? "Selected" : "Select").font(.system(size: 11)).foregroundStyle(Pal.tint)
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                .padding(8).background(Pal.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Group {
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error, typedFile == nil {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Pal.red).multilineTextAlignment(.center)
                        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    Text("This folder is empty.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { LazyVStack(spacing: 2) { ForEach(entries) { e in row(e) } } }
                }
            }
            .frame(height: 230)
            .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                if !checked.isEmpty {
                    Text("\(checked.count) selected").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                PrimaryButton(title: "Add", enabled: !checked.isEmpty, tint: Pal.tint) { onAdd(checked) }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Pal.base)
        .onAppear { go("/var/log") }
    }

    private func row(_ e: RemoteFile) -> some View {
        let isChecked = checked.contains(e.path)
        let added = alreadyAdded.contains(e.path)
        return Button {
            if e.isDir { go(e.path) } else if !added { toggle(e.path) }
        } label: {
            HStack(spacing: 8) {
                Image(lucideSymbol: e.isDir ? "folder.fill" : "doc.text").foregroundStyle(e.isDir ? Pal.tint : Pal.subtext).frame(width: 16)
                Text(verbatim: e.name).font(.system(size: 12.5)).foregroundStyle(added ? Pal.overlay : Pal.text).lineLimit(1)
                Spacer(minLength: 0)
                if added {
                    Text("Added").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                } else if !e.isDir {
                    Image(lucideSymbol: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13)).foregroundStyle(isChecked ? Pal.tint : Pal.overlay)
                } else {
                    Image(lucideSymbol: "chevron.right").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isChecked ? Pal.tint.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func toggle(_ p: String) {
        if let i = checked.firstIndex(of: p) { checked.remove(at: i) } else { checked.append(p) }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    /// Manual paths navigate directories; otherwise offer file addition, including nonexistent paths.
    private func submitTyped() {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("/") else { error = String(localized: "Enter an absolute path starting with /"); typedFile = nil; return }
        go(t, typed: true)
    }

    private func go(_ target: String, typed: Bool = false) {
        let t = target.isEmpty ? "/" : target
        loading = true; error = nil; typedFile = nil
        Task {
            let r = await fs.list(t)
            await MainActor.run {
                switch r {
                case .success(let files):
                    path = t; input = t
                    entries = files.sorted {
                        if $0.isDir != $1.isDir { return $0.isDir }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .failure(let e):
                    if typed {
                        typedFile = t   // Treat nondirectory input as a file; validate existence when opening remotely.
                        input = t
                    } else {
                        path = t; entries = []; error = e.message
                    }
                }
                loading = false
            }
        }
    }
}
