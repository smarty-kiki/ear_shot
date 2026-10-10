#!/usr/bin/env bash
#
# 构建「耳录」.app
#
#   ./build.sh                 构建到 dist/EarShot.app（本机架构）
#   ./build.sh --universal     同时编 arm64 + x86_64 并 lipo 成通用二进制
#   ./build.sh --debug         不优化、带调试符号
#   ./build.sh --clean         先删掉 build/ 和产物 .app
#
# 版本号读仓库根的 VERSION 文件。环境变量：
#   VERSION / BUILD_NUMBER / TARGET_ARCH  覆盖版本与架构
#   DIST_DIR            产物落点（默认 dist/；release.sh 指到隔离目录，
#                       免得打包动作踩本机正在验收/授权的那个 dist/EarShot.app）
#   CODESIGN_IDENTITY   签名身份（默认 "-" ad-hoc；换固定证书可让
#                       屏幕录制授权跨重建保持）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="EarShot"
BUNDLE_ID="com.smarty.earshot"
# SpeechAnalyzer / SpeechTranscriber 是 macOS 26 起才有的 API，所以最低版本比
# 隔壁任务坞（14.0）高一截。音频采集那边用的 SCStream.captureMicrophone 也是 15+。
MIN_MACOS="26.0"

BUILD="$ROOT/build"
# 产物落点。默认 dist/；release.sh 用 DIST_DIR 指到 release/stage
DIST="${DIST_DIR:-$ROOT/dist}"
BUNDLE="$DIST/$APP_NAME.app"

UNIVERSAL=0
DEBUG=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --debug)     DEBUG=1 ;;
    --clean)     CLEAN=1 ;;
    -h|--help)   sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（试试 --help）" >&2; exit 2 ;;
  esac
done

# ---------- 版本 ----------
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

# ---------- 清理 ----------
if [ "$CLEAN" = "1" ]; then
  echo "==> 清理"
  rm -rf "$BUILD"
  # 某些环境下删 .app 会被拦，拦不住就原样覆盖
  rm -rf "$BUNDLE" 2>/dev/null || echo "   (无法删除旧 bundle，将原样覆盖)"
fi

mkdir -p "$BUILD" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

SDK="$(xcrun --show-sdk-path)"
HOST_ARCH="$(uname -m)"

COMMON_FLAGS=(
  -sdk "$SDK"
  -framework AppKit
  -framework SwiftUI
  -framework AVFoundation
  -framework Speech            # SpeechAnalyzer / SpeechTranscriber
  -framework ScreenCaptureKit  # 系统音频 + 麦克风采集
  -framework CoreMedia
  -Xfrontend -disable-sandbox      # 关掉编译器自带的 sandbox，避免中间产物写入被拦
)
if [ "$DEBUG" = "1" ]; then
  OPT_FLAGS=(-Onone -g)
else
  OPT_FLAGS=(-O -whole-module-optimization)
fi

compile_arch() {          # $1 = arch，$2 = 输出路径
  echo "      - $1"
  swiftc "${OPT_FLAGS[@]}" -target "$1-apple-macos${MIN_MACOS}" \
    "${COMMON_FLAGS[@]}" "$ROOT"/Sources/*.swift -o "$2"
}

echo "==> 编译  版本 $VERSION (build $BUILD_NUMBER)"
if [ "$UNIVERSAL" = "1" ]; then
  echo "   target: universal (arm64 + x86_64)"
  compile_arch arm64  "$BUILD/$APP_NAME-arm64"
  compile_arch x86_64 "$BUILD/$APP_NAME-x86_64"
  lipo -create -output "$BUILD/$APP_NAME" \
       "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
  rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
else
  ARCH="${TARGET_ARCH:-$HOST_ARCH}"
  echo "   target: $ARCH"
  compile_arch "$ARCH" "$BUILD/$APP_NAME"
fi

echo "==> 组装 bundle"
cp -f "$BUILD/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp -f "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp -f "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi
[ -f "$ROOT/LICENSE" ] && cp -f "$ROOT/LICENSE" "$BUNDLE/Contents/Resources/LICENSE"

# 提示音：耳录用系统原版就够了，不做放大版，直接从这里拷。
if [ -d "$ROOT/Resources/Sounds" ]; then
  rm -rf "$BUNDLE/Contents/Resources/Sounds"
  cp -R "$ROOT/Resources/Sounds" "$BUNDLE/Contents/Resources/Sounds"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $BUILD_NUMBER" \
                        "$BUNDLE/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "==> 签名（身份：${SIGN_ID}）"
# ad-hoc（-）每次重建签名都会变，而屏幕录制授权绑签名 —— 重建后要重新授权。
# 想让它跨重建保持：用固定签名身份（自签证书就行），
#   CODESIGN_IDENTITY="<证书名>" ./build.sh
# 再把产物固定放在 /Applications 或 ~/Applications 再授权，就基本一劳永逸。
if codesign --force --sign "$SIGN_ID" --timestamp=none "$BUNDLE" 2>/dev/null; then
  if [ "$SIGN_ID" = "-" ]; then
    echo "   已签名（ad-hoc；不是 Developer ID，首次打开需右键→打开）"
  else
    echo "   已签名（${SIGN_ID}）"
  fi
else
  if [ "$SIGN_ID" = "-" ]; then
    echo "   签名失败，本地仍可运行"
  else
    echo "   签名失败（钥匙串里没有「${SIGN_ID}」这个身份？），本地仍可运行"
  fi
fi

SIZE="$(du -sh "$BUNDLE" | cut -f1)"
CDHASH="$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
echo
echo "==> 完成"
echo "    产物   $BUNDLE  ($SIZE)"
echo "    版本   $VERSION ($BUILD_NUMBER)"
echo "    架构   $(lipo -archs "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || echo "$HOST_ARCH")"
# 授权认什么：ad-hoc 认 CDHash（重建就变 → 要重新授权）；固定身份认证书（重建不变）
if [ "$SIGN_ID" = "-" ] && [ -n "$CDHASH" ]; then
  echo "    CDHash ${CDHASH}（ad-hoc 授权认哈希，重建就变）"
fi
