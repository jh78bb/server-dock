import SwiftUI

/// Generate-key dialog.
struct GenerateKeyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: SSHKeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Generate Key").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
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
                    labeled(String(localized: "Name")) { ThemedTextField(placeholder: "My Key", text: $name) }
                    labeled(String(localized: "Type")) {
                        ThemedDropdown(options: SSHKeyType.allCases.map { (value: $0, label: $0.label) },
                                       selection: $type)
                    }
                    labeled(String(localized: "Comment")) { ThemedTextField(placeholder: "user@host (optional, appended to the public key)", text: $comment) }
                    labeled(String(localized: "Passphrase")) { ThemedSecureField(placeholder: "(Optional, encrypts the private key)", text: $passphrase) }
                    Text("The private key is stored securely in the system Keychain and never written to disk in plaintext. You can copy the public key to a server's authorized_keys anytime.")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
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
                    model.generateKey(name: name.trimmingCharacters(in: .whitespaces),
                                      type: type, comment: comment, passphrase: passphrase)
                    dismiss()
                } label: {
                    Text("Generate").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}

/// Key details show type/fingerprint/time, public-key copy, and deletion.
struct KeyDetailView: View {
    @ObservedObject var model: AppModel
    let key: SSHKey
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "key.fill").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                Text(key.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    info(String(localized: "Type"), key.type.label)
                    info(String(localized: "Fingerprint"), key.fingerprint.isEmpty ? "—" : key.fingerprint)
                    info(String(localized: "Passphrase Protected"), key.hasPassphrase ? String(localized: "Encrypted") : String(localized: "None"))
                    info(String(localized: "Created"), Self.dateFormatter.string(from: key.createdAt))
                    if !key.comment.isEmpty { info(String(localized: "Comment"), key.comment) }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Public Key").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            Spacer()
                            Button {
                                model.copyPublicKey(key); copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", lucideSymbol: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11)).foregroundStyle(Pal.mauve)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                        Text(key.publicKey)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Button {
                    model.deleteKey(key); dismiss()
                } label: {
                    Text("Delete").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.red)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                Button { dismiss() } label: {
                    Text("Close").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480, height: 440)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
