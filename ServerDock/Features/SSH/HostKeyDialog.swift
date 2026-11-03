import AppKit
import SwiftUI

/// First-connection host fingerprint verification dialog.
struct HostKeyDialog: View {
    let pending: PendingHostKey
    @ObservedObject private var theme = ThemeManager.shared

    private var info: HostKeyInfo { pending.info }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header.
                HStack(spacing: 10) {
                    Image(lucideSymbol: info.changed ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18)).foregroundStyle(info.changed ? Pal.red : Pal.yellow)
                    Text(info.changed ? "Warning: Host key has changed" : "First connection: verify the host fingerprint")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.bottom, info.changed ? 10 : 14)

                // A changed host key may mean a rebuilt server/key rotation or a man-in-the-middle attack; show a prominent warning.
                if info.changed {
                    Text("The recorded host key doesn't match the current one. Don't continue unless you just reinstalled the server or changed the key — this could be a man-in-the-middle attack.")
                        .font(.system(size: 12)).foregroundStyle(Pal.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }

                HStack(spacing: 8) {
                    Text("Target:").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                    Text("\(info.host):\(info.port)")
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 16)

                HStack {
                    Text("Current fingerprint (verify the SHA256):")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    Spacer()
                    copyButton(String(localized: "Copy SHA256"), info.sha256)
                    copyButton(String(localized: "Copy MD5"), info.md5)
                }
                .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 6) {
                    if !info.sha256.isEmpty {
                        Text(info.sha256).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Pal.subtext).textSelection(.enabled)
                    }
                    if !info.md5.isEmpty {
                        Text(info.md5).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Pal.subtext).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 18)

                Button { pending.respond(.once) } label: {
                    Text("Continue Once (Don't Save)")
                        .font(.system(size: 13)).foregroundStyle(Color(hex: 0x89b4fa))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.bottom, 22)

                HStack(spacing: 10) {
                    Spacer()
                    Button { pending.respond(.cancel) } label: {
                        Text("Cancel Connection").font(.system(size: 13)).foregroundStyle(Pal.text)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.10), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button { pending.respond(.save) } label: {
                        Text("Trust and Save").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Pal.green, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func copyButton(_ title: String, _ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Pal.fill(0.10), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(!value.isEmpty)
        .disabled(value.isEmpty)
        .opacity(value.isEmpty ? 0.4 : 1)
    }
}
