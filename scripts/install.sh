#!/bin/zsh
# GitHub Releases에서 최신 Canopy DMG를 받아 검증하고 /Applications(또는 ~/Applications)에 설치한 뒤 실행한다.
#   curl -fsSL https://raw.githubusercontent.com/sangeui/Canopy/main/scripts/install.sh | zsh
set -euo pipefail

REPO="${CANOPY_REPO:-sangeui/Canopy}"
API_URL="https://api.github.com/repos/$REPO/releases/latest"

echo "Canopy 최신 버전을 확인하는 중..."
RELEASE_JSON="$(curl -fsSL -H "Accept: application/vnd.github+json" "$API_URL")"

TAG="$(printf '%s' "$RELEASE_JSON" | plutil -extract tag_name raw -o - - 2>/dev/null || true)"
if [[ -z "$TAG" ]]; then
    echo "최신 릴리스를 찾지 못했습니다: https://github.com/$REPO/releases" >&2
    exit 1
fi
VERSION="${TAG#v}"

DMG_URL="$(printf '%s' "$RELEASE_JSON" | grep -oE 'https://[^"]+\.dmg' | head -1 || true)"
SHA_URL="$(printf '%s' "$RELEASE_JSON" | grep -oE 'https://[^"]+\.dmg\.sha256' | head -1 || true)"

STAGE="$(mktemp -d)"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

if [[ -z "$DMG_URL" ]]; then
    echo "릴리스($TAG)에 미리 빌드된 DMG가 없어 소스를 받아 바로 빌드 및 설치합니다..."
    TAR_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
    mkdir -p "$STAGE/src"
    curl -fL --progress-bar "$TAR_URL" -o "$STAGE/source.tar.gz"
    tar -xzf "$STAGE/source.tar.gz" -C "$STAGE/src" --strip-components=1
    cd "$STAGE/src"
    ./make-app.sh --install --version "$VERSION"
    exit 0
fi

DMG_FILE="$STAGE/Canopy-$VERSION.dmg"
echo "Canopy $VERSION 다운로드 중..."
curl -fL --progress-bar "$DMG_URL" -o "$DMG_FILE"

if [[ -n "$SHA_URL" ]]; then
    EXPECTED="$(curl -fsSL "$SHA_URL" | awk '{print $1}')"
    ACTUAL="$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')"
    if [[ -n "$EXPECTED" && "$EXPECTED" != "$ACTUAL" ]]; then
        echo "체크섬(SHA-256)이 일치하지 않아 설치를 중단합니다." >&2
        exit 1
    fi
fi

MOUNT="$STAGE/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$DMG_FILE" -readonly -nobrowse -noverify -noautoopen -mountpoint "$MOUNT" >/dev/null

if [[ ! -d "$MOUNT/Canopy.app" ]]; then
    echo "디스크 이미지 안에서 Canopy.app을 찾지 못했습니다." >&2
    exit 1
fi

TARGET="/Applications/Canopy.app"
if [[ ! -w "/Applications" ]]; then
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/Canopy.app"
fi

echo "$TARGET 에 설치하는 중..."
if pgrep -f "$TARGET/Contents/MacOS/Canopy" >/dev/null 2>&1; then
    osascript -e 'tell application id "dev.sangeui.canopy" to quit' >/dev/null 2>&1 || pkill -f "$TARGET/Contents/MacOS/Canopy" 2>/dev/null || true
    sleep 0.5
fi

rm -rf "$TARGET"
cp -R "$MOUNT/Canopy.app" "$TARGET"
# 미공증 빌드여도 Gatekeeper 차단 없이 바로 열리도록 격리 속성을 지운다
xattr -cr "$TARGET" 2>/dev/null || true

hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
MOUNT=""

open -a "$TARGET"
echo "Canopy $VERSION 설치 및 실행 완료 ($TARGET)"
