import SwiftUI

/// Keys activity sidebar lists/searches managed keys and offers details/public copy/delete.
struct KeysPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    private var keys: [SSHKey] {
        let q = model.query.lowercased()
        guard !q.isEmpty else { return model.sshKeys }
        return model.sshKeys.filter {
            $0.name.lowercased().contains(q)
                || $0.fingerprint.lowercased().contains(q)
                || $0.comment.lowercased().contains(q)
        }
    }

    var body: some View {
        if model.sshKeys.isEmpty {
            emptyState
        } else if keys.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("No Matching Keys").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(keys) { KeyRow(key: $0, model: model) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(lucideSymbol: "key").font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("No keys yet").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("Generate a new key, or import an existing private key").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            HStack(spacing: 8) {
                Button { model.showGenerateKey = true } label: {
                    Text("Generate").font(.system(size: 12)).foregroundStyle(Pal.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.075), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Button { model.presentImportKey() } label: {
                    Text("Import").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

private struct KeyRow: View {
    let key: SSHKey
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button { model.detailKey = key } label: {
            HStack(spacing: 10) {
                Image(lucideSymbol: "key").font(.system(size: 16)).foregroundStyle(Pal.subtext).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                    Text("\(key.type.label) · \(shortFingerprint)")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                }
                Spacer(minLength: 0)
                if key.hasPassphrase {
                    Image(lucideSymbol: "lock.fill").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(hover ? Pal.fill(0.055) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy Public Key") { model.copyPublicKey(key) }
            Button("View Details") { model.detailKey = key }
            Divider()
            Button("Delete", role: .destructive) { model.deleteKey(key) }
        }
    }

    /// Abbreviate SHA256 fingerprints, e.g. SHA256:abc123...wxyz.
    private var shortFingerprint: String {
        let raw = key.fingerprint.replacingOccurrences(of: "SHA256:", with: "")
        guard raw.count > 14 else { return key.fingerprint }
        return "SHA256:\(raw.prefix(6))…\(raw.suffix(4))"
    }
}
