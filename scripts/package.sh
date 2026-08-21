#!/usr/bin/env bash
# 竹点阅读：一键打 Release 安装包（DMG）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/ZhudotReader.xcodeproj"
SCHEME="ZhudotReader"
APP_NAME="竹点阅读.app"
VOL_NAME="竹点阅读"
ENTITLEMENTS="$ROOT/ZhudotReader/App/ZhudotReader.entitlements"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
STAGE=""
MOUNT=""
TMP_DMG=""
UNIVERSAL=0
INSTALL=0
OPEN_DMG=0

usage() {
    cat <<'EOF'
用法: scripts/package.sh [选项]

  默认编译 Release，签名后打出 dist/竹点阅读-<当天日期>.dmg
  版本号取本机当天日期，例如 2026.08.21；同日再打会覆盖同名安装包。
  磁盘镜像里是应用和「应用程序」文件夹的快捷方式，拖进去即可安装。

选项:
  --install      打完包后同时安装到 /Applications
  --open         完成后打开 DMG
  --universal    打 arm64 + x86_64 通用包（默认只编当前芯片）
  -h, --help     显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=1 ;;
        --open) OPEN_DMG=1 ;;
        --universal) UNIVERSAL=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

log() { printf '\n▸ %s\n' "$*"; }

detach_volume() {
    local name="$1"
    for suffix in "" " 1" " 2" " 3"; do
        local vol="/Volumes/${name}${suffix}"
        if [[ -d "$vol" ]]; then
            hdiutil detach "$vol" -quiet -force 2>/dev/null || true
        fi
    done
}

cleanup() {
    if [[ -n "${MOUNT:-}" && -d "$MOUNT" ]]; then
        hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    fi
    detach_volume "$VOL_NAME"
    if [[ -n "${STAGE:-}" && -d "$STAGE" ]]; then
        rm -rf "$STAGE"
    fi
    if [[ -n "${TMP_DMG:-}" && -f "$TMP_DMG" ]]; then
        rm -f "$TMP_DMG"
    fi
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$DIST" "$DERIVED"
detach_volume "$VOL_NAME"

ARCH_ARGS=(ONLY_ACTIVE_ARCH=YES)
if [[ "$UNIVERSAL" -eq 1 ]]; then
    ARCH_ARGS=(ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64")
fi

VERSION="$(date +%Y.%m.%d)"
BUILD="$(date +%Y%m%d%H%M)"
FINAL_DMG="$DIST/${VOL_NAME}-${VERSION}.dmg"
TMP_DMG="$DIST/.packaging-${VERSION}.dmg"

log "编译 Release ${VERSION} (${BUILD})"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    "${ARCH_ARGS[@]}" \
    build

APP_SRC="$DERIVED/Build/Products/Release/$APP_NAME"
if [[ ! -d "$APP_SRC" ]]; then
    echo "没有找到编译产物: $APP_SRC" >&2
    exit 1
fi

log "签名 ${APP_NAME} ${VERSION}"
codesign --force --deep --options runtime --sign - --entitlements "$ENTITLEMENTS" "$APP_SRC"
codesign --verify --deep --strict "$APP_SRC"
xattr -cr "$APP_SRC" 2>/dev/null || true

log "组装 DMG"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/zhudot-dmg-XXXX")"
ditto "$APP_SRC" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

rm -f "$TMP_DMG" "$FINAL_DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    "$TMP_DMG" >/dev/null

MOUNT="$(hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen | awk '/\/Volumes\//{print $NF; exit}')"
if [[ -z "$MOUNT" || ! -d "$MOUNT" ]]; then
    echo "无法挂载临时磁盘镜像" >&2
    exit 1
fi

if osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {280, 160, 900, 560}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        delay 0.4
        set position of item "$APP_NAME" of container window to {160, 180}
        set position of item "Applications" of container window to {460, 180}
        close
        open
        update without registering applications
        delay 0.8
    end tell
end tell
EOF
then
    log "已排好安装窗口"
else
    log "跳过窗口排版，仍可拖进应用程序"
fi

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""
sleep 0.4
detach_volume "$VOL_NAME"

log "压缩 DMG"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$TMP_DMG"
TMP_DMG=""
xattr -cr "$FINAL_DMG" 2>/dev/null || true

if [[ "$INSTALL" -eq 1 ]]; then
    log "安装到 /Applications"
    pkill -f "$APP_NAME/Contents/MacOS/竹点阅读" 2>/dev/null || true
    sleep 0.2
    rm -rf "/Applications/$APP_NAME"
    ditto "$APP_SRC" "/Applications/$APP_NAME"
    xattr -cr "/Applications/$APP_NAME" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME" >/dev/null
fi

SIZE="$(du -sh "$FINAL_DMG" | awk '{print $1}')"
echo
echo "完成"
echo "  版本:   ${VERSION} (${BUILD})"
echo "  安装包: $FINAL_DMG"
echo "  大小:   $SIZE"
if [[ "$INSTALL" -eq 1 ]]; then
    echo "  本机:   /Applications/$APP_NAME"
fi
echo
echo "第一次打开若被拦截：右键应用 → 打开。"

if [[ "$OPEN_DMG" -eq 1 ]]; then
    open "$FINAL_DMG"
fi
