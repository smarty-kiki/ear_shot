#!/usr/bin/env bash
#
# 打包发布 DMG（以及一键发 GitHub Release）
#
#   ./release.sh                 构建 + 打包 release/EarShot-<版本>.dmg
#   ./release.sh --universal     同上，但打 arm64 + x86_64 通用二进制
#   ./release.sh --publish       打包后打 tag 并创建 GitHub Release（需 gh 已登录）
#   ./release.sh --help
#
# 产物（release/ 目录，不进 git）：
#   EarShot-<版本>.dmg          拖进「应用程序」即可安装
#   EarShot-<版本>.dmg.sha256   校验和
#
# 构建落在隔离目录 release/stage/，不碰 dist/EarShot.app ——
# 本机正在授权 / 验收的那个是另一份，两边别互相踩。
#
# 签名：默认 ad-hoc；CODESIGN_IDENTITY="<证书名>" 可换固定签名身份
# （重建后屏幕录制授权不掉）。未公证，别的机器首次打开要右键→打开。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="EarShot"
RELEASE_DIR="$ROOT/release"
STAGE="$RELEASE_DIR/stage"

UNIVERSAL=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --publish)   PUBLISH=1 ;;
    -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（试试 --help）" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "VERSION 文件是空的（版本号读它）" >&2; exit 1; }
TAG="v$VERSION"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
SHA="$DMG.sha256"

# ---------- 发布前置检查（只有 --publish 才需要） ----------
if [ "$PUBLISH" = "1" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "工作树不干净，先提交（发布要对得上 git 记录）" >&2; exit 1; }
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "不在 main 分支上" >&2; exit 1; }
  git fetch origin main --quiet
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD 跟 origin/main 不一致，先推" >&2; exit 1; }
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG 已存在 —— 升 VERSION，或者先想清楚要不要删旧 tag" >&2; exit 1
  fi
fi

# ---------- 构建（隔离目录，不碰 dist/） ----------
echo "==> 构建 $APP_NAME $VERSION（落 release/stage，dist/ 不动）"
rm -rf "$STAGE"
mkdir -p "$STAGE"
if [ "$UNIVERSAL" = "1" ]; then
  DIST_DIR="$STAGE" ./build.sh --universal
else
  DIST_DIR="$STAGE" ./build.sh
fi

# ---------- 组装 DMG 内容 ----------
echo "==> 组装 DMG"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'EOF'
耳录 EarShot —— 下载解压后把 EarShot.app 拖进左边的「应用程序」。

系统要求：macOS 26 或更新。

首次打开如果被系统拦下（本应用未做 Apple 公证），右键点图标 →
打开 → 再点一次「打开」，只需要这一次。
首次录音前会要「屏幕录制」和「麦克风」权限，应用里会一步步提示。

校验下载完整性：
  shasum -a 256 -c EarShot-<版本>.dmg.sha256
EOF

# ---------- 打包 ----------
echo "==> hdiutil 打包"
hdiutil create -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
hdiutil verify "$DMG" >/dev/null
(cd "$RELEASE_DIR" && shasum -a 256 "$APP_NAME-$VERSION.dmg" > "$APP_NAME-$VERSION.dmg.sha256")

echo
echo "==> 完成"
echo "    DMG    $DMG  ($(du -h "$DMG" | cut -f1))"
echo "    校验   $(cat "$SHA")"
echo "    内容   EarShot.app + /Applications 软链 + 安装说明.txt"
echo "    签名   ad-hoc / 自签，未公证 —— 别的机器首次打开要右键→打开"

# ---------- 发布（可选） ----------
if [ "$PUBLISH" = "1" ]; then
  echo
  echo "==> 发 GitHub Release $TAG"
  git tag -a "$TAG" -m "$APP_NAME $VERSION"
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" "$SHA" \
    --title "$APP_NAME $VERSION" --generate-notes
  echo "    已发布：$(gh release view "$TAG" --json url -q .url)"
fi
