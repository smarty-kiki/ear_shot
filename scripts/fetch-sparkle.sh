#!/usr/bin/env bash
#
# 下载固定版本的 Sparkle 到 .sparkle/<版本>/（不进 git），打印目录
#
#   scripts/fetch-sparkle.sh
#   SPARKLE_DIR=/path/to/sparkle scripts/fetch-sparkle.sh   # 用已有目录（离线/临时验证）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEST="$ROOT/.sparkle/$SPARKLE_VERSION"

complete() {
  [ -d "$1/Sparkle.framework" ] && [ -x "$1/bin/generate_appcast" ]
}

if [ -n "${SPARKLE_DIR:-}" ]; then
  case "$SPARKLE_DIR" in /*) ;; *) SPARKLE_DIR="$PWD/$SPARKLE_DIR" ;; esac
  if complete "$SPARKLE_DIR"; then
    printf '%s\n' "$SPARKLE_DIR"
    exit 0
  fi
  echo "SPARKLE_DIR 不完整：$SPARKLE_DIR" >&2
  exit 1
fi

if complete "$DEST"; then
  printf '%s\n' "$DEST"
  exit 0
fi

echo "==> 下载 Sparkle $SPARKLE_VERSION" >&2
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
# GitHub CDN 偶尔卡在 0 字节：低于 1KB/s 持续 60 秒就断开重试，别无限等
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
  --speed-limit 1024 --speed-time 60 \
  -o "$TMP/sparkle.tar.xz" "$URL" >&2
printf '%s  %s\n' "$SPARKLE_SHA256" "$TMP/sparkle.tar.xz" | shasum -a 256 -c - >&2

mkdir -p "$TMP/unpack"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/unpack"
if ! complete "$TMP/unpack"; then
  echo "Sparkle 包里缺 framework 或 generate_appcast" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/unpack" "$DEST"
printf '%s\n' "$DEST"
