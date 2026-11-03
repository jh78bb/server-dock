import SwiftUI

/// Collect variable values before running/inserting snippets, substitute after confirmation, and send to the terminal.
/// Use the same centered overlay styling as ask-mode password prompts.
struct SnippetRunDialog: View {
    let request: SnippetRunRequest
    let onConfirm: ([String: String]) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]
    @ObservedObject private var theme = ThemeManager.shared

    private var allFilled: Bool {
        request.variables.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text(request.run ? "Run Script" : "Insert Script")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("\"\(request.snippet.name)\" requires the following variables:")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.variables, id: \.self) { v in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(v).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            ThemedTextField(verbatim: v, text: Binding(
                                get: { values[v] ?? "" },
                                set: { values[v] = $0 }
                            ))
                        }
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "Cancel", action: onCancel)
                    PrimaryButton(title: request.run ? "Run" : "Insert", enabled: allFilled) { onConfirm(values) }
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// Ask-mode snippet action dialog chooses Insert/Run and whether to remember.
/// Default to Insert Only to avoid immediate execution; remembered choices persist and can be reset in settings.
struct SnippetActionDialog: View {
    let snippet: Snippet
    let onChoose: (_ run: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var remember = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("Use Script").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("How should \"\(snippet.name)\" be sent to the current Terminal?")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: remember) { remember.toggle() }
                    Text("Remember my choice (can be changed in Settings)")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { remember.toggle() }
                }
                HStack(spacing: 10) {
                    SecondaryButton(title: "Cancel", action: onCancel)
                    Spacer()
                    SecondaryButton(title: "Run Directly") { onChoose(true, remember) }
                    PrimaryButton(title: "Insert Only") { onChoose(false, remember) }
                }
            }
            .padding(20)
            .frame(width: 400)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}
