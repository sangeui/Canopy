# Canopy 배포하기

Canopy는 GitHub Releases에 DMG로 올린다. `v`로 시작하는 태그를 올리면 GitHub Actions(`.github/workflows/release.yml`)가 테스트, 빌드, 서명, 공증, DMG 만들기, 업로드를 차례로 한다.

## 처음 한 번: Apple 서명·공증 준비

다른 사람의 Mac에서 경고 없이 열리려면 Developer ID로 서명하고 Apple 공증을 받아야 한다. Apple Developer Program 가입이 필요하다.

1. Xcode › Settings › Accounts › Manage Certificates에서 "Developer ID Application" 인증서를 만든다.
2. 키체인 접근에서 그 인증서를 개인 키와 함께 .p12로 내보내고 암호를 정한다.
3. appleid.apple.com › 로그인 및 보안 › 앱 암호에서 공증에 쓸 암호를 하나 만든다.
4. GitHub 저장소의 Settings › Secrets and variables › Actions에 아래 값을 넣는다.

   | 이름 | 값 |
   |---|---|
   | `DEVELOPER_ID_P12` | `base64 -i developer-id.p12 \| pbcopy`로 복사한 값 |
   | `DEVELOPER_ID_P12_PASSWORD` | 2번에서 정한 암호 |
   | `APPLE_ID` | Apple 계정 메일 |
   | `APPLE_TEAM_ID` | 개발자 계정의 Team ID (10자리) |
   | `APPLE_APP_PASSWORD` | 3번의 앱 암호 |

Secrets가 없으면 워크플로는 임시 서명으로 DMG를 만들어 올린다. 그 DMG는 열 때 Gatekeeper가 막고, 릴리스 노트에 여는 방법(시스템 설정 › 개인정보 보호 및 보안의 "그래도 열기" 또는 `xattr -cr /Applications/Canopy.app`)이 적힌다.

## 배포할 때

```bash
# 1) (선택) docs/releases/v0.2.0.md 파일을 작성해 두거나,
#    주석 태그(annotated tag)에 변경 요약을 적으면 릴리스 노트 맨 위에 들어간다.
git tag -a v0.2.0 -m "인앱 업데이트와 원클릭 설치 스크립트 추가"
git push origin v0.2.0
```

Actions 탭에서 진행을 볼 수 있다. 끝나면 Releases에 `Canopy-0.2.0.dmg`와 `Canopy-0.2.0.dmg.sha256`이 올라가고, `scripts/make-release-notes.sh`가 `docs/releases/v0.2.0.md`(또는 태그 설명)와 직전 태그 뒤의 커밋 분류(주요 기능·개선·문제 해결), 설치 방법, 체크섬을 합쳐 노트를 적는다. 이미 Canopy를 설치한 사용자에게는 다음 실행 때 하단 상태 줄 배너와 **Canopy › 업데이트 확인…** 창으로 새 버전과 릴리스 노트가 안내되며, 앱 안에서 바로 받아 교체·재실행할 수 있다.

릴리스 노트가 어떻게 나올지 미리 보려면:

```bash
./scripts/make-release-notes.sh 0.2.0
```

## 이 Mac에서 직접 만들 때

```bash
# 공증 정보를 키체인에 한 번 저장해 둔다
xcrun notarytool store-credentials canopy-notary --apple-id <메일> --team-id <TEAMID> --password <앱 암호>

SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" ./make-app.sh --universal --version 0.2.0
SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" NOTARY_PROFILE=canopy-notary ./scripts/make-dmg.sh 0.2.0
```

결과는 `build/Canopy-0.2.0.dmg`다. `SIGN_IDENTITY`를 빼면 이 Mac에서만 쓸 수 있는 임시 서명으로 만든다.

## DMG 창

DMG를 열면 "Canopy 설치" 창에 앱과 응용 프로그램 폴더가 화살표 양옆에 놓인다. 배경은 `Packaging/dmg-background.tiff`이고, 문구를 바꾸려면 `swift scripts/make-dmg-background.swift Packaging/dmg-background.tiff`로 다시 그린다. 창 배치는 `make-dmg.sh`가 Finder에 시켜 정하는데, Finder를 부를 수 없으면 꾸밈 없는 창으로 만든다.

## 빌드 종류

| 명령 | 쓰임 |
|---|---|
| `./make-app.sh --install` | 이 Mac에서 쓰는 빌드. 임시 서명 |
| `./make-app.sh --dev --install` | 화면 확인용 명령(분산 알림, 실행 인자)이 들어간 개발 빌드. 다른 프로그램이 알림으로 앱을 조작할 수 있으니 배포하지 않는다. 이름은 Canopy Dev, 아이콘에 DEV 띠가 붙고 설정을 따로 저장한다 |
| `./make-app.sh --universal --version X` | 배포용. Apple Silicon과 Intel을 함께 담는다 |

## 확인할 것

- 배포 빌드에는 확인용 명령이 없어야 한다: `strings build/Canopy.app/Contents/MacOS/Canopy | grep -c dev.sangeui.canopy.debug`가 0
- 서명: `codesign --verify --strict --verbose=2 build/Canopy.app`
- 공증: `spctl --assess --type open --context context:primary-signature -v build/Canopy-0.2.0.dmg`가 `accepted`
- 첫 워크플로는 GitHub의 macOS 러너에 있는 Xcode로 빌드한다. 이 Mac과 Swift 버전이 달라 빌드가 깨질 수 있으니 처음 한 번은 Actions 기록을 확인한다.
