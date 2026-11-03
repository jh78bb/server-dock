import AppKit
import SwiftUI

/// In-app English/Korean privacy policy uses literals to avoid fragmenting long legal text into xcstrings.
/// Policy basis: no personal-data collection/analytics/tracking; connections target user-owned servers.
/// Any future iCloud sync uses only the user's own iCloud, sending nothing to developers.
struct PrivacyPolicyView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var isKorean: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("ko")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(effectiveDate)
                        .font(.system(size: 11))
                        .foregroundStyle(Pal.overlay)
                    ForEach(sections.indices, id: \.self) { i in
                        section(sections[i].0, sections[i].1)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 620)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack {
            Text(verbatim: isKorean ? "개인정보 처리방침" : "Privacy Policy")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Pal.text)
            Spacer()
            Button { dismiss() } label: {
                Image(lucideSymbol: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Pal.text)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(Pal.subtext)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectiveDate: String {
        isKorean ? "시행일: 2026년 7월 1일" : "Effective date: July 1, 2026"
    }

    private var sections: [(String, String)] {
        isKorean ? Self.korean : Self.english
    }

    private static let english: [(String, String)] = [
        ("Overview",
         "ServerDock does not collect, store, or upload any of your personal information. The app has no account system, no analytics, no tracking, and contains no third-party SDKs or ads that gather data."),
        ("Where your data lives",
         "The hosts, sessions, scripts, and other configuration you create are stored locally on your own Mac. Passwords and key passphrases are kept in the system Keychain — never written to disk in plaintext, and never leaving your device."),
        ("Network connections",
         "The only network connections ServerDock makes are the ones you initiate yourself: SSH, SFTP, Windows Remote Desktop, and port forwarding. These happen directly between your Mac and the servers you configure. That traffic never passes through the developer, and the developer cannot see any of it."),
        ("Software updates",
         "The non-App-Store build periodically checks an update server for a new version; this transmits no personal information. Builds installed from the App Store are updated by the App Store."),
        ("iCloud sync (future)",
         "A future version may offer optional iCloud sync to keep your configuration in sync across your own devices. It uses your own Apple iCloud account; data is stored only in your private iCloud and is never sent to the developer or any third-party server, nor to any private network."),
        ("Children's privacy",
         "ServerDock is not directed at children and does not knowingly collect personal information from anyone."),
        ("Changes to this policy",
         "If this policy changes, the updated version ships inside the app with a revised effective date shown above."),
        ("Contact",
         "For any privacy questions, open an issue in the project repository: github.com/jh78bb/server-dock"),
    ]

    private static let korean: [(String, String)] = [
        ("개요",
         "ServerDock는 사용자의 개인정보를 수집·저장·업로드하지 않습니다. 앱에는 계정 시스템, 분석, 추적 기능이 없으며, 데이터 수집을 목적으로 하는 서드파티 SDK나 광고도 포함되어 있지 않습니다."),
        ("데이터 저장 위치",
         "추가한 호스트, 세션, 코드 스니펫 등의 설정은 모두 사용자의 Mac에 로컬로 저장됩니다. 비밀번호와 키 암호는 시스템 키체인(Keychain)에 보관되며, 평문으로 디스크에 기록되거나 기기 밖으로 전송되지 않습니다."),
        ("네트워크 연결",
         "ServerDock가 만드는 네트워크 연결은 사용자가 직접 시작한 것뿐입니다. SSH, SFTP, Windows 원격 데스크톱, 포트 포워딩은 모두 사용자의 Mac과 사용자가 설정한 서버 사이에서 직접 이루어집니다. 이 트래픽은 개발자를 거치지 않으며, 개발자는 그 내용을 볼 수 없습니다."),
        ("소프트웨어 업데이트",
         "App Store 외 배포판은 새 버전이 있는지 업데이트 서버에 주기적으로 확인하며, 이 과정에서 개인정보는 전송되지 않습니다. App Store에서 설치한 버전은 App Store가 업데이트를 담당합니다."),
        ("iCloud 동기화(예정)",
         "향후 버전에서는 사용자 본인의 여러 기기 간 설정을 동기화하는 선택형 iCloud 동기화를 제공할 수 있습니다. 이 기능은 사용자 본인의 Apple iCloud 계정을 사용하며, 데이터는 사용자의 개인 iCloud에만 저장되고 개발자나 서드파티 서버, 사설 네트워크로 전송되지 않습니다."),
        ("아동의 개인정보",
         "ServerDock는 아동을 대상으로 하지 않으며, 누구의 개인정보도 의도적으로 수집하지 않습니다."),
        ("정책 변경",
         "이 정책이 변경되면 새 버전과 함께 앱 안에서 제공되며, 위의 시행일이 갱신됩니다."),
        ("문의",
         "개인정보 관련 문의는 프로젝트 저장소에 이슈로 남겨 주세요: github.com/jh78bb/server-dock"),
    ]
}
