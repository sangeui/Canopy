#!/bin/zsh
# release로 빌드한 실행 파일을 Canopy.app 번들로 감싼다.
#   ./make-app.sh                     build/Canopy.app만 만든다 (이 Mac용, 임시 서명)
#   ./make-app.sh --install           만든 뒤 /Applications(안 되면 ~/Applications)에 넣고 다시 실행한다
#   ./make-app.sh --dev [--install]   화면 확인용 명령(분산 알림·실행 인자)을 넣은 개발 빌드. 배포에 쓰지 않는다.
#                                     이름(Canopy Dev)·번들 ID·아이콘(DEV 띠)이 따로라 설치한 앱과 나란히 떠도 구별되고
#                                     설정(UserDefaults)도 섞이지 않는다. build/Canopy Dev.app으로 만든다.
#   ./make-app.sh --universal         Apple Silicon과 Intel을 함께 담는다 (배포용)
#   ./make-app.sh --version 1.2.0     번들 버전. 없으면 0.1.0
#   SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" ./make-app.sh --universal
#                                     Developer ID로 서명하고 hardened runtime을 켠다. 없으면 임시 서명(이 Mac에서만).
set -euo pipefail
cd "$(dirname "$0")"

DEV=0
INSTALL=0
UNIVERSAL=0
VERSION="0.1.0"
while (( $# > 0 )); do
    case "$1" in
        --dev) DEV=1 ;;
        --install) INSTALL=1 ;;
        --universal) UNIVERSAL=1 ;;
        --version) VERSION="$2"; shift ;;
    esac
    shift
done

BUILD_ARGS=(-c release)
(( UNIVERSAL )) && BUILD_ARGS+=(--arch arm64 --arch x86_64)
(( DEV )) && BUILD_ARGS+=(-Xswiftc -DCANOPY_DEV)
swift build "${BUILD_ARGS[@]}" 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -3
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

NAME="Canopy"
BUNDLE_ID="dev.sangeui.canopy"
if (( DEV )); then
    NAME="Canopy Dev"
    BUNDLE_ID="dev.sangeui.canopy.dev"
fi
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Canopy" "$APP/Contents/MacOS/Canopy"
cp "Sources/Canopy/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM 리소스 번들. Bundle.module이 Contents/Resources에서 찾는다.
cp -R "$BIN/Canopy_Canopy.bundle" "$APP/Contents/Resources/"
if (( DEV )); then
    # Dock(앱이 실행 중에 AppIcon.png로 바꾼다)과 Finder(AppIcon.icns)에 모두 DEV 띠를 넣는다
    ICONS="$(mktemp -d)"
    swift scripts/make-dev-icon.swift Sources/Canopy/Resources/AppIcon.png "$ICONS/AppIcon.png"
    mkdir "$ICONS/AppIcon.iconset"
    for px in 16 32 128 256 512; do
        sips -z $px $px "$ICONS/AppIcon.png" --out "$ICONS/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
        sips -z $((px * 2)) $((px * 2)) "$ICONS/AppIcon.png" --out "$ICONS/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"
    RESOURCES="$APP/Contents/Resources/Canopy_Canopy.bundle/Contents/Resources"
    cp "$ICONS/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    cp "$ICONS/AppIcon.png" "$RESOURCES/AppIcon.png"
    rm -rf "$ICONS"
fi
# macOS 26부터는 Icon Composer 아이콘(Assets.car)을 쓴다. 라이트·다크·투명·틴트 중 무엇을 보일지는 시스템 설정을 따른다.
# 그 전 시스템은 CFBundleIconFile(AppIcon.icns)을 쓴다. 개발 빌드는 DEV 띠를 붙인 icns만 쓴다.
ICON_NAME_KEY=""
if (( ! DEV )); then
    ICONS="$(mktemp -d)"
    if xcrun actool Packaging/AppIcon.icon --compile "$ICONS" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --output-partial-info-plist "$ICONS/partial.plist" >/dev/null 2>&1 && [[ -f "$ICONS/Assets.car" ]]; then
        cp "$ICONS/Assets.car" "$APP/Contents/Resources/Assets.car"
        ICON_NAME_KEY="<key>CFBundleIconName</key><string>AppIcon</string>"
    else
        echo "actool로 Icon Composer 아이콘을 만들지 못해 AppIcon.icns만 넣습니다 (Xcode 26 이상 필요)" >&2
    fi
    rm -rf "$ICONS"
fi
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Canopy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    $ICON_NAME_KEY
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>ko</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Sangeui Seo</string>
    <key>NSAppleEventsUsageDescription</key><string>터미널 앱에서 Claude 로그인 명령을 실행하려고 씁니다.</string>
</dict>
</plist>
PLIST
RESOURCES="$APP/Contents/Resources/Canopy_Canopy.bundle"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    # 배포용: Developer ID + hardened runtime + 보안 타임스탬프. 공증에 모두 필요하다.
    # 리소스 번들이 번들 모양(Info.plist가 있음)이면 안쪽부터 따로 서명해야 검증을 통과한다
    if [[ -f "$RESOURCES/Contents/Info.plist" ]]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$RESOURCES"
    fi
    codesign --force --options runtime --timestamp \
        --entitlements Packaging/Canopy.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    # 이 Mac에서 쓰는 임시 서명. 다른 Mac에서는 Gatekeeper가 막는다.
    if [[ -f "$RESOURCES/Contents/Info.plist" ]]; then
        codesign --force --sign - "$RESOURCES" >/dev/null 2>&1 || true
    fi
    codesign --force --entitlements Packaging/Canopy.entitlements --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "built $APP"

if [[ $INSTALL == 1 ]]; then
    TARGET="/Applications/$NAME.app"
    if ! { rm -rf "$TARGET" 2>/dev/null && cp -R "$APP" "$TARGET" 2>/dev/null; }; then
        mkdir -p "$HOME/Applications"
        TARGET="$HOME/Applications/$NAME.app"
        rm -rf "$TARGET"
        cp -R "$APP" "$TARGET"
    fi
    # 실행 중이면 곱게 끝낸다. 창 위치·저장소·칸·고른 커밋은 저장돼 있어서 새 앱이 같은 자리로 돌아온다.
    # 실행 파일 이름은 둘 다 Canopy라 경로로 찾는다. 개발 빌드를 설치할 때 쓰던 앱을 끄지 않게.
    RUNNING="$TARGET/Contents/MacOS/Canopy"
    if pgrep -f "$RUNNING" >/dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || pkill -f "$RUNNING" 2>/dev/null || true
        for _ in $(seq 1 30); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.1; done
        pkill -f "$RUNNING" 2>/dev/null || true
    fi
    sleep 0.5
    open -a "$TARGET"
    echo "installed and launched $TARGET"
fi
