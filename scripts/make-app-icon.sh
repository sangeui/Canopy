#!/bin/zsh
# 앱 아이콘을 다시 만든다. Packaging/AppIcon.icon(Icon Composer 형식)의 잎 레이어를 그리고,
# macOS 26보다 오래된 시스템과 앱 안(정보 화면·DMG)에서 쓸 AppIcon.png·AppIcon.icns를 기본 모양으로 뽑는다.
#   ./scripts/make-app-icon.sh
# 바탕색과 유리 효과, 라이트/다크 구분은 Packaging/AppIcon.icon/icon.json에서 바꾼다.
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || { echo "Icon Composer가 든 Xcode 26 이상이 필요합니다" >&2; exit 1; }

swift scripts/make-app-icon.swift Packaging/AppIcon.icon/Assets

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$ICTOOL" Packaging/AppIcon.icon --export-image --output-file Sources/Canopy/Resources/AppIcon.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
mkdir "$WORK/AppIcon.iconset"
for px in 16 32 128 256 512; do
    "$ICTOOL" Packaging/AppIcon.icon --export-image --output-file "$WORK/AppIcon.iconset/icon_${px}x${px}.png" \
        --platform macOS --rendition Default --width $px --height $px --scale 1 >/dev/null
    "$ICTOOL" Packaging/AppIcon.icon --export-image --output-file "$WORK/AppIcon.iconset/icon_${px}x${px}@2x.png" \
        --platform macOS --rendition Default --width $px --height $px --scale 2 >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Sources/Canopy/Resources/AppIcon.icns
cp Sources/Canopy/Resources/AppIcon.png docs/icon.png
echo "made Packaging/AppIcon.icon, Sources/Canopy/Resources/AppIcon.png, AppIcon.icns"
