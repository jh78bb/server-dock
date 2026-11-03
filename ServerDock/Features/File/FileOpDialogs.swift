import SwiftUI

/// Rename dialog with ConfirmDialog's custom style.
struct RenameDialog: View {
    let originalName: String
    let title: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @ObservedObject private var theme = ThemeManager.shared

    init(originalName: String, title: String = String(localized: "Rename"),
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.originalName = originalName
        self.title = title
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    private var canConfirm: Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.contains("/")
    }
    private func submit() { if canConfirm { onConfirm(name) } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                ThemedTextField(placeholder: "Name", text: $name, autofocus: true, onSubmit: submit)
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "Cancel", action: onCancel)
                    PrimaryButton(title: "OK", enabled: canConfirm, action: submit)
                }
            }
            .padding(20).frame(width: 360)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// Permission editor synchronizes nine owner/group/other read/write/execute checkboxes with octal.
struct ChmodDialog: View {
    let fileName: String
    let onConfirm: (Int) -> Void
    let onCancel: () -> Void
    @State private var mode: Int
    @State private var octalText: String
    @ObservedObject private var theme = ThemeManager.shared

    init(fileName: String, initialMode: Int, onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _mode = State(initialValue: initialMode & 0o777)
        _octalText = State(initialValue: String(format: "%03o", initialMode & 0o777))
    }

    private let groups: [(label: String, shift: Int)] = [(String(localized: "Owner"), 6), (String(localized: "Group"), 3), (String(localized: "Other"), 0)]
    private let perms: [(label: String, bit: Int)] = [(String(localized: "Read"), 4), (String(localized: "Write"), 2), (String(localized: "Run"), 1)]

    private func isOn(_ shift: Int, _ bit: Int) -> Bool { (mode >> shift) & bit != 0 }
    private func toggle(_ shift: Int, _ bit: Int) {
        mode ^= (bit << shift)
        octalText = String(format: "%03o", mode)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(fileName).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Pal.subtext).lineLimit(1).truncationMode(.middle)

                grid.padding(.top, 2)

                HStack(spacing: 8) {
                    Text("Permission Code").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    ThemedTextField(placeholder: "755", text: $octalText)
                        .frame(width: 72)
                        .onChange(of: octalText) { t in
                            // Parse only the final three octal digits; do not write octalText back and create update loops.
                            let digits = String(t.filter { "01234567".contains($0) }.suffix(3))
                            if let v = Int(digits, radix: 8) { mode = v & 0o777 }
                        }
                    Spacer()
                    Text(symbolic).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "Cancel", action: onCancel)
                    PrimaryButton(title: "Apply") { onConfirm(mode & 0o777) }
                }
                .padding(.top, 2)
            }
            .padding(20).frame(width: 340)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }

    private var grid: some View {
        VStack(spacing: 9) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 60, height: 14)   // Set a fixed height too, or the placeholder greedily fills the dialog vertically.
                ForEach(perms, id: \.label) { p in
                    Text(p.label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .frame(width: 50)
                }
            }
            ForEach(groups, id: \.label) { g in
                HStack(spacing: 0) {
                    Text(g.label).font(.system(size: 12)).foregroundStyle(Pal.text)
                        .frame(width: 60, alignment: .leading)
                    ForEach(perms, id: \.label) { p in
                        ThemedCheckbox(isOn: isOn(g.shift, p.bit)) { toggle(g.shift, p.bit) }
                            .frame(width: 50)
                    }
                }
            }
        }
    }

    /// Display rwxr-xr-x permissions.
    private var symbolic: String {
        var s = ""
        for g in groups {
            s += isOn(g.shift, 4) ? "r" : "-"
            s += isOn(g.shift, 2) ? "w" : "-"
            s += isOn(g.shift, 1) ? "x" : "-"
        }
        return s
    }
}
