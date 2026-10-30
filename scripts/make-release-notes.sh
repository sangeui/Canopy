#!/bin/zsh
# 태그와 커밋 히스토리를 읽어 읽기 쉬운 마크다운 릴리스 노트를 만든다.
#   ./scripts/make-release-notes.sh 0.2.0 [출력파일]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.2.0}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
OUT="${2:-}"
REPO="${CANOPY_REPO:-sangeui/Canopy}"

generate() {
    HAS_CURATED=0
    # 1. docs/releases/v버전.md 파일이 있으면 맨 위에 둔다
    if [[ -f "docs/releases/$TAG.md" ]]; then
        cat "docs/releases/$TAG.md"
        echo
        HAS_CURATED=1
    elif git rev-parse "$TAG" >/dev/null 2>&1; then
        # 주석 태그(annotated tag)에 직접 적은 설명이 있으면 맨 위에 둔다
        TAG_BODY="$(git for-each-ref --format='%(contents:body)' "refs/tags/$TAG" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
        if [[ -n "$TAG_BODY" ]]; then
            echo "$TAG_BODY"
            echo
        fi
    fi

    # 2. 이전 태그 이후 커밋을 종류별로 분류해 적는다 (수동 문서가 있으면 이전 태그가 있을 때만 커밋 목록을 덧붙인다)
    PREV_TAG=""
    if git rev-parse HEAD >/dev/null 2>&1; then
        if git rev-parse "$TAG" >/dev/null 2>&1; then
            PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
            RANGE="${PREV_TAG:+$PREV_TAG..}$TAG"
        else
            PREV_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
            RANGE="${PREV_TAG:+$PREV_TAG..}HEAD"
        fi

        FEATURES=()
        IMPROVEMENTS=()
        FIXES=()
        OTHERS=()

        if [[ "$HAS_CURATED" -eq 0 || -n "$PREV_TAG" ]]; then
            while IFS=$'\t' read -r hash subject; do
                [[ -z "$hash" || -z "$subject" ]] && continue
                [[ "$subject" =~ ^Merge\  ]] && continue
                clean="$(printf '%s' "$subject" | sed -E 's/^(feat|fix|refactor|perf|docs|chore|style|test)(\([^)]+\))?:[[:space:]]*//')"
                entry="- $clean (\`$hash\`)"
                if [[ "$subject" =~ ^(feat|기능) || "$subject" == *"추가"* || "$subject" == *"새 "* || "$subject" == *"구현"* || "$subject" == *"지원"* ]]; then
                    FEATURES+=("$entry")
                elif [[ "$subject" =~ ^(fix|버그) || "$subject" == *"수정"* || "$subject" == *"고침"* || "$subject" == *"해결"* || "$subject" == *"오류"* || "$subject" == *"방지"* ]]; then
                    FIXES+=("$entry")
                elif [[ "$subject" =~ ^(refactor|perf|style) || "$subject" == *"개선"* || "$subject" == *"정리"* || "$subject" == *"다듬"* || "$subject" == *"변경"* || "$subject" == *"전환"* ]]; then
                    IMPROVEMENTS+=("$entry")
                else
                    OTHERS+=("$entry")
                fi
            done < <(git log "$RANGE" --no-merges --format="%h%x09%s" 2>/dev/null || true)
        fi

        if (( ${#FEATURES[@]} + ${#IMPROVEMENTS[@]} + ${#FIXES[@]} + ${#OTHERS[@]} > 0 )); then
            echo "## 무엇이 바뀌었나요"
            echo
            if (( ${#FEATURES[@]} > 0 )); then
                echo "### 주요 기능 및 추가"
                printf '%s\n' "${FEATURES[@]}"
                echo
            fi
            if (( ${#IMPROVEMENTS[@]} > 0 )); then
                echo "### 개선 및 사용성"
                printf '%s\n' "${IMPROVEMENTS[@]}"
                echo
            fi
            if (( ${#FIXES[@]} > 0 )); then
                echo "### 문제 해결"
                printf '%s\n' "${FIXES[@]}"
                echo
            fi
            if (( ${#OTHERS[@]} > 0 )); then
                echo "### 기타 변경"
                printf '%s\n' "${OTHERS[@]}"
                echo
            fi
            if [[ -n "$PREV_TAG" ]]; then
                echo "**전체 변경 비교**: [\`$PREV_TAG...$TAG\`](https://github.com/$REPO/compare/$PREV_TAG...$TAG)"
                echo
            fi
        fi
    fi

    # 3. 설치 및 업데이트 안내
    echo "## 설치 및 업데이트"
    echo
    echo "### 방법 1. 터미널 한 줄 설치 (권장)"
    echo "다운로드, 체크섬 검증, \`/Applications\` 설치, 격리 속성 해제를 한 번에 처리합니다."
    echo "\`\`\`bash"
    echo "curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | zsh"
    echo "\`\`\`"
    echo
    echo "### 방법 2. DMG 파일로 설치"
    echo "1. 아래 Assets에서 \`Canopy-$VERSION.dmg\`를 받아 열고 **Canopy**를 **응용 프로그램** 폴더로 끌어다 놓습니다."
    echo "2. 이미 Canopy를 쓰고 있다면 앱 안의 **Canopy › 업데이트 확인…** 또는 상단 업데이트 배너에서 한 번에 업데이트할 수 있습니다."
    echo
    if [[ -z "${SIGN_IDENTITY:-}" ]]; then
        echo "> **안내**: 이 빌드는 Apple 공증을 받지 않았습니다. DMG로 직접 설치한 뒤 처음 열 때 막히면 **시스템 설정 › 개인정보 보호 및 보안**에서 **\"그래도 열기\"**를 누르거나, 터미널에서 \`xattr -cr /Applications/Canopy.app\`을 실행하세요."
        echo
    fi
    if [[ -f "build/Canopy-$VERSION.dmg.sha256" ]]; then
        echo "**SHA-256 (\`Canopy-$VERSION.dmg\`)**: \`$(cut -d' ' -f1 "build/Canopy-$VERSION.dmg.sha256")\`"
    fi
}

if [[ -n "$OUT" ]]; then
    generate > "$OUT"
else
    generate
fi
