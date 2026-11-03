import SwiftUI

/// Generate-key dialog writing to the real directory, separate from Keychain-managed [[GenerateKeyView]].
struct SSHKeyGenerateSheet: View {
    @ObservedObject var model: SSHKeyManagerModel
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var type: SSHKeyGenerationType = .ed25519
    @State private var fileName = "id_ed25519"
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
                    labeled(String(localized: "Type")) {
                        ThemedDropdown(options: SSHKeyGenerationType.allCases.map { (value: $0, label: $0.title) },
                                       selection: $type)
                        .onChange(of: type) { newType in
                            if fileName.isEmpty || SSHKeyGenerationType.allCases.map(\.defaultFileName).contains(fileName) {
                                fileName = newType.defaultFileName
                            }
                        }
                    }
                    labeled(String(localized: "File Name")) { ThemedTextField(placeholder: "id_ed25519", text: $fileName) }
                    labeled(String(localized: "Comment")) { ThemedTextField(placeholder: "user@host (optional)", text: $comment) }
                    labeled(String(localized: "Passphrase")) { ThemedSecureField(placeholder: "(Optional, encrypts the private key)", text: $passphrase) }
                    Text("Written directly to \(model.directoryPath)/\(fileName.isEmpty ? "…" : fileName) (+ .pub).")
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
                    model.generate(SSHKeyGenerationRequest(fileName: fileName.trimmingCharacters(in: .whitespaces),
                                                           type: type, comment: comment, passphrase: passphrase))
                    dismiss()
                } label: {
                    Text("Generate").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.tint, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(fileName.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(fileName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}

/// Shared new-filename dialog for rename/copy.
struct SSHKeyRenameSheet: View {
    @ObservedObject var model: SSHKeyManagerModel
    let key: SSHKeyItem
    let title: String
    var initialName: String? = nil
    let onSubmit: (String) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            VStack(alignment: .leading, spacing: 8) {
                Text("New Name").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                ThemedTextField(placeholder: "id_ed25519", text: $name, autofocus: true)
                if key.kind == .completePair {
                    Text("Renames both this file and its .pub counterpart.")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)

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
                    onSubmit(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                } label: {
                    Text("OK").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.tint, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 420, height: 220)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { name = initialName ?? key.name }
    }
}

/// Add/change passphrase dialog; encrypted keys require the old passphrase. Empty new passphrase removes encryption.
struct SSHKeyPassphraseSheet: View {
    @ObservedObject var model: SSHKeyManagerModel
    let key: SSHKeyItem

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmPassphrase = ""

    private var mismatch: Bool { newPassphrase != confirmPassphrase }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(key.isPassphraseProtected ? "Change Passphrase" : "Add Passphrase")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            VStack(alignment: .leading, spacing: 14) {
                if key.isPassphraseProtected {
                    labeled(String(localized: "Current Passphrase")) {
                        ThemedSecureField(placeholder: "", text: $oldPassphrase)
                    }
                }
                labeled(String(localized: "New Passphrase")) {
                    ThemedSecureField(placeholder: "(Leave empty to remove passphrase)", text: $newPassphrase)
                }
                labeled(String(localized: "Confirm New Passphrase")) {
                    ThemedSecureField(placeholder: "", text: $confirmPassphrase)
                }
                if mismatch && !confirmPassphrase.isEmpty {
                    Text("Passphrases don't match").font(.system(size: 11)).foregroundStyle(Pal.red)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)

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
                    model.changePassphrase(key, oldPassphrase: oldPassphrase, newPassphrase: newPassphrase)
                    dismiss()
                } label: {
                    Text("Save").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.tint, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(mismatch)
                .opacity(mismatch ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 420, height: key.isPassphraseProtected ? 340 : 280)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}
