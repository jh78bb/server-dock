import SwiftUI

/// One-time password dialog before connecting an ask-mode host; never write the password to disk/Keychain.
struct AskPasswordDialog: View {
    let host: Host
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @ObservedObject private var theme = ThemeManager.shared

    private var target: String {
        guard let s = host.ssh else { return host.name }
        return "\(s.user)@\(s.host)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("Enter Password").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("Connect to \(target) for this session only, without saving.")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                ThemedSecureField(placeholder: "Password", text: $password)
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "Cancel", action: onCancel)
                    PrimaryButton(title: "Connect", enabled: !password.isEmpty) { onConfirm(password) }
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}
