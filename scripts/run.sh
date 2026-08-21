#!/usr/bin/env bash
# 竹点阅读：构建并启动应用（默认 Release）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/ZhudotReader.xcodeproj"
SCHEME="ZhudotReader"
APP_NAME="竹点阅读.app"
DERIVED="$ROOT/build/DerivedData"
CONFIGURATION="Release"

if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION="Debug"
elif [[ $# -gt 0 ]]; then
    echo "用法: scripts/run.sh [--debug]" >&2
    exit 2
fi

APP_PATH="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME"

log() { printf '\n▸ %s\n' "$*"; }

cd "$ROOT"
mkdir -p "$DERIVED"

log "构建 $CONFIGURATION 应用"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=YES \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "没有找到构建产物: $APP_PATH" >&2
    exit 1
fi

log "启动竹点阅读"
pkill -f '/竹点阅读.app/Contents/MacOS/竹点阅读$' 2>/dev/null || true
sleep 0.2
open "$APP_PATH"

echo "已启动: $APP_PATH"
