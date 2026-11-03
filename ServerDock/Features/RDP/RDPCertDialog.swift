import AppKit
import SwiftUI

/// RDP certificate trust dialog for first connections or certificate changes.
/// Selecting Always trust this computer persists trust in [[RDPCertTrustStore]];
/// otherwise accept once; cancel rejects the connection. changed=true shows a stronger man-in-the-middle warning.
struct RDPCertDialog: View {
    let prompt: RDPCertPrompt
    @State private var alwaysTrust = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header: lock for first connection, warning triangle for changed certificates.
                HStack(spacing: 10) {
                    Image(lucideSymbol: prompt.changed ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(prompt.changed ? Pal.red : Pal.yellow)
                    Text(prompt.changed ? "Warning: Remote Desktop certificate has changed" : "First connection: verify the Remote Desktop certificate")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.bottom, 14)

                Text(prompt.changed
                     ? "This host's certificate does not match the one you previously trusted. If you didn't change it yourself, there may be a man-in-the-middle risk. Please confirm carefully."
                     : "This certificate couldn't be traced back to a trusted root certificate (self-signed certificates are common on internal or personal servers). Verify the fingerprint before deciding whether to trust it.")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)

                infoRow(String(localized: "Target"), "\(prompt.host):\(prompt.port)", mono: true)
                if let s = prompt.subject, !s.isEmpty { infoRow(String(localized: "Body"), s) }
                if let i = prompt.issuer, !i.isEmpty { infoRow(String(localized: "Issuer"), i) }

                HStack {
                    Text("Certificate fingerprint (verify against the server)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    Spacer()
                    copyButton(String(localized: "Copy Fingerprint"), prompt.fingerprint)
                }
                .padding(.top, 6).padding(.bottom, 8)

                // Fingerprints may contain full PEM data or certificate chains; bound the height and allow scrolling to keep the dialog manageable.
                ScrollView {
                    Text(prompt.fingerprint.isEmpty ? String(localized: "(No fingerprint information)") : prompt.fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Pal.subtext).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 150)
                .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.08), lineWidth: 1))

                if prompt.changed, let old = prompt.oldFingerprint, !old.isEmpty {
                    Text("Previously trusted fingerprint: \(old)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Pal.overlay).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }

                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: alwaysTrust) { alwaysTrust.toggle() }
                    Text("Always trust this computer (\(prompt.host))")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { alwaysTrust.toggle() }
                }
                .padding(.top, 18).padding(.bottom, 20)

                HStack(spacing: 10) {
                    Spacer()
                    Button { prompt.respond(.reject) } label: {
                        Text("Cancel").font(.system(size: 13)).foregroundStyle(Pal.text)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.10), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button { prompt.respond(alwaysTrust ? .trust : .once) } label: {
                        Text("Continue").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(prompt.changed ? Pal.red : Pal.green, in: RoundedRectangle(cornerRadius: 8))
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

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text("\(label):").font(.system(size: 13)).foregroundStyle(Pal.overlay)
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(Pal.subtext).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.bottom, 6)
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
