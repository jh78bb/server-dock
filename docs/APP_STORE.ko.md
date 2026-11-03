[English](APP_STORE.md) · **한국어**

# Mac App Store 제출 가이드

Mac App Store도 추가 배포 경로로 추진할 계획입니다. 이 문서는 기존 `ServerDock-MAS` 타깃의 구현 상태와 제출 전 검증 항목을 정리합니다. 먼저 CI 기반 GitHub Releases 배포를 준비하고, 샌드박스 동작과 심사 요건을 함께 검토해 App Store 출시를 추진합니다. 프로젝트의 비상업적 운영 방침과 [현재 라이선스](../LICENSE.md)는 유지합니다.

직접 배포 도구는 [RELEASING.md](RELEASING.md), 의존성 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 참고하세요.

ServerDock는 두 개의 앱 타깃(라인업)을 같은 소스로 빌드한다.

| | 타깃 / scheme | 구성 | Sparkle | 샌드박스 | 로컬 터미널 |
|---|---|---|---|---|---|
| 웹(Developer ID, GitHub) | `ServerDock` | Debug / Release | 링크·임베드 | 없음 | 있음 |
| Mac App Store | `ServerDock-MAS` | DebugMAS / ReleaseMAS | **없음** | 있음(`ServerDock-MAS.entitlements`) | 숨김 |

- MAS 빌드: `xcodebuild -scheme ServerDock-MAS -configuration ReleaseMAS archive`
- 웹 배포(`scripts/package-app.sh`, `scripts/release.sh`)는 기존 그대로 `ServerDock` scheme을 쓴다.
- 버전 번호는 두 타깃 모두 `ServerDock/Info.plist`가 유일한 출처다. MAS 타깃은 빌드 후 스크립트로 Info.plist의 `SU*` 키만 지운다.
- 프라이버시 매니페스트: `ServerDock/Resources/PrivacyInfo.xcprivacy`(UserDefaults, 파일 타임스탬프, 시스템 부팅 시각 사유 선언 / 추적·수집 없음).
- 샌드박스에서 SSH 키 관리자는 사용자가 고른 `.ssh` 폴더를 보안 범위 북마크로 저장해 다음 실행에도 접근한다.

## App Review 메모 초안 (App Store Connect › 심사 정보 › 메모)

> ServerDock is an SSH / SFTP / Remote Desktop client for developers and system administrators.
> It does not require a ServerDock account. Connection profiles and history are stored locally; credentials use macOS Keychain. To try it, add a host with **Hosts › Add** and connect.
>
> **Test server (please use this):**
> - Host: `<REVIEW_HOST>`  Port: `<PORT>`
> - User: `<USER>`  Password: `<PASSWORD>`
> - Remote Desktop test host (optional): `<RDP_HOST>` / `<RDP_USER>` / `<RDP_PASSWORD>`
>
> **What to try:** connect → the terminal and the file panel (right side) open together; right-click a file for Tail / editor; right-click a folder for Analyze Disk Usage; open the Host Overview for live CPU/memory/disk charts.
>
> Notes: the local terminal and the local Mac host are hidden in this sandboxed build. There is no in-app updater. The SSH Key Manager asks you to choose your `.ssh` folder once (sandbox). AI Assistant runs an AI CLI *on the user's own server* and only when the user opens it; The CLI may send prompts and server content to its provider; its behavior and permissions must be explained in the submitted build.

## 구현 기록 (2026-09-29 기준)

이전 구현 점검에서 기록한 항목입니다. 현재 제출 준비가 끝났다는 뜻은 아닙니다.

완료

- [x] Sparkle을 웹 타깃 전용으로 분리(`ServerDock-MAS`에는 링크·임베드 없음, `SU*` 키 제거)
- [x] `PrivacyInfo.xcprivacy` 추가
- [x] 샌드박스에서 SSH 키 관리자가 `.ssh` 폴더를 선택·북마크하도록 대응(컴파일만 확인, 실제 샌드박스 동작은 미확인)
- [x] 심사 메모 초안 작성

다음 검증 항목

- [ ] `ReleaseMAS` 아카이브 → Validate App로 실제 검증(서명 포함)
- [ ] 샌드박스(`DebugMAS`) 실행 상태에서 SSH 키 관리자 폴더 선택·재실행 후 접근 확인
- [ ] Tail, 폴더 용량 분석, 명령어 도구함, 스니펫 사이드바가 샌드박스에서 문제없는지 확인
- [ ] 아래 체크리스트 전부

## 제출 전 체크리스트 (코드로 해결할 수 없는 항목)

- [ ] 심사용 **테스트 서버**를 준비하고 App Store Connect의 비공개 심사 정보에만 접속 정보를 입력한다. 공개 문서의 `<...>`는 실제 값으로 바꾸지 않는다.
- [ ] `ITSAppUsesNonExemptEncryption`(현재 `false`)을 다시 판단한다. OpenSSL/libssh2로 SSH 암호화를 직접 하므로 해당 빌드에 적용되는 수출 규정 분류를 확인한다.
- [ ] 개인정보 처리방침 URL, 지원 URL, 앱 프라이버시 라벨을 실제 데이터 처리 및 외부 CLI 동작과 대조해 등록한다.
- [ ] 비상업적 배포 방침을 유지하며 원본 라이선스와 App Store 배포 조건의 적합성을 확인한다.
- [ ] 오픈소스 고지문(OpenSSL, libssh2, FreeRDP, SwiftTerm, CodeEdit 등)을 앱 안(정보 화면)에 넣는다.
- [ ] 정보 화면·개인정보·지원 링크와 사이트 링크를 `jh78bb/server-dock`, `https://serverdock.papo.co.kr/`에 맞춰 검증하고 앱 이름은 ServerDock으로 유지한다.
- [ ] Apple Distribution 서명·프로비저닝 프로파일을 설정하고 `ReleaseMAS`로 아카이브 → Xcode Organizer의 **Validate App**을 통과시킨다.
- [ ] AI 어시스턴트 첫 사용 시 「서버의 AI CLI가 외부 AI 서비스로 데이터를 보낼 수 있음」 안내를 넣을지 결정한다.
