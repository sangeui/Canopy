#!/bin/zsh
# build/Canopy.app을 DMG로 묶는다. 서명·공증 정보가 있으면 DMG도 서명하고 공증받아 붙인다(staple).
#   ./scripts/make-dmg.sh 1.2.0
# 환경 변수 (없으면 그 단계를 건너뛴다)
#   SIGN_IDENTITY           "Developer ID Application: 이름 (TEAMID)"
#   NOTARY_PROFILE          `xcrun notarytool store-credentials`로 저장한 프로필 이름 (이 Mac에서 할 때)
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   프로필 대신 직접 줄 때 (GitHub Actions)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="build/Canopy.app"
DMG="build/Canopy-$VERSION.dmg"
[[ -d "$APP" ]] || { echo "먼저 ./make-app.sh로 $APP을 만드세요" >&2; exit 1; }
# 개발 빌드(--dev)는 다른 프로그램이 알림으로 앱을 조작할 수 있어 배포하면 안 된다
if strings "$APP/Contents/MacOS/Canopy" | grep -q "dev.sangeui.canopy.debug"; then
    echo "$APP은 개발 빌드(--dev)입니다. ./make-app.sh로 다시 만든 뒤 DMG를 만드세요" >&2
    exit 1
fi

# 창에 앱과 응용 프로그램 폴더 바로가기를 나란히 두고 배경에 안내 문구를 깐다. 끌어다 놓으면 설치된다.
# 배경은 scripts/make-dmg-background.swift로 그린다. 아이콘 자리는 그 배경의 화살표 양옆이다.
VOLUME="Canopy 설치"
LINK="응용 프로그램"
STAGE="$(mktemp -d)"
RW="$STAGE/rw.dmg"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir "$STAGE/root"
cp -R "$APP" "$STAGE/root/"
ln -s /Applications "$STAGE/root/$LINK"
mkdir "$STAGE/root/.background"
cp Packaging/dmg-background.tiff "$STAGE/root/.background/background.tiff"
# 디스크 크기를 아이콘까지 담을 만큼 잡아 두려고 미리 넣는다. Finder가 지우므로 꾸민 뒤에 다시 넣는다.
cp Sources/Canopy/Resources/AppIcon.icns "$STAGE/root/.VolumeIcon.icns"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE/root" -ov -format UDRW -fs APFS "$RW" >/dev/null
MOUNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')"
# 같은 이름의 디스크가 이미 붙어 있으면 "Canopy 설치 1"처럼 붙는다. Finder에는 실제 이름으로 묻는다.
DISK="$(basename "$MOUNT")"

# 창 모양은 Finder가 .DS_Store에 적게 한다. Finder를 부를 수 없는 곳(권한이 없거나 화면이 없는 CI 러너)에서는
# 꾸밈 없이 두 아이콘만 있는 창으로 만든다.
if [[ -z "${CI:-}" ]]; then
    if ! osascript - "$DISK" "$LINK" <<'APPLESCRIPT'
on run {disk_name, link_name}
    -- 러너에서 Finder 권한 창에 걸려 멈추지 않게 한다
    with timeout of 8 seconds
    tell application "Finder"
        tell disk disk_name
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 840, 548}
            set options to the icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 112
            set text size of options to 13
            set background picture of options to file ".background:background.tiff"
            set position of item "Canopy.app" of container window to {200, 238}
            set position of item link_name of container window to {440, 238}
            update without registering applications
            delay 1
            close
        end tell
    end tell
    end timeout
end run
APPLESCRIPT
    then
        echo "Finder로 창을 꾸미지 못해 기본 창으로 만듭니다" >&2
    fi
fi
# 창 제목 옆 디스크 아이콘을 앱 아이콘으로. Finder가 창을 정리하며 이 파일을 지우므로 꾸민 뒤에 넣는다.
cp Sources/Canopy/Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
sync
rm -rf "$MOUNT/.fseventsd"
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -quiet -force
MOUNT=""
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "made $DMG"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    echo "signed $DMG"

    NOTARY_ARGS=()
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
        NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
    fi
    if (( ${#NOTARY_ARGS[@]} > 0 )); then
        # DMG 안의 앱까지 함께 검사받는다. 통과하면 DMG에 공증 표를 붙여 인터넷 없이도 확인되게 한다.
        xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
        echo "notarized $DMG"
    else
        echo "공증 정보가 없어 공증을 건너뜁니다. 다른 Mac에서는 처음 열 때 경고가 뜹니다." >&2
    fi
fi

shasum -a 256 "$DMG" | sed "s|build/||" > "$DMG.sha256"
echo "checksum $(cat "$DMG.sha256")"
