#!/usr/bin/env bash
#
# 打包发布 DMG + appcast（以及一键发 GitHub Release）
#
#   ./release.sh                 构建 + 打包 release/EarShot-<版本>.dmg + appcast.xml（通用二进制）
#   ./release.sh --universal     兼容保留：产物本来就是 arm64 + x86_64，加不加一样
#   ./release.sh --publish       打包后打 tag、draft 上传，再切正式发布（需 gh 已登录）
#   ./release.sh --help
#
# 产物（release/ 目录，不进 git）：
#   EarShot-<版本>.dmg          拖进「应用程序」即可安装
#   EarShot-<版本>.dmg.sha256   校验和
#   appcast.xml                 Sparkle 更新清单；Release 的 latest/download/appcast.xml 指向它
#
# 构建落在隔离目录 release/stage/，不碰 dist/EarShot.app ——
# 本机正在授权 / 验收的那个是另一份，两边别互相踩。
#
# 签名：固定自签身份（默认「Smarty Kiki Signing」，CODESIGN_IDENTITY 可覆盖）。
# 音频采集授权绑签名证书，发布一律用同一张证书；未公证，首次打开要右键→打开。
# Sparkle 的 EdDSA 私钥在登录钥匙串里（generate_appcast 读取，绝不进仓库）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="EarShot"
RELEASE_DIR="$ROOT/release"
STAGE="$RELEASE_DIR/stage"
REPO_SLUG="smarty-kiki/ear_shot"
RELEASE_URL="https://github.com/$REPO_SLUG/releases"
FEED_URL="$RELEASE_URL/latest/download/appcast.xml"

PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --universal) ;;   # 兼容保留：产物一律通用二进制
    --publish)   PUBLISH=1 ;;
    -h|--help)   sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（试试 --help）" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "VERSION 文件是空的（版本号读它）" >&2; exit 1; }
TAG="v$VERSION"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
SHA="$DMG.sha256"
APPCAST="$RELEASE_DIR/appcast.xml"
SIGN_ID="${CODESIGN_IDENTITY:-Smarty Kiki Signing}"

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

# ---------- 签名身份 ----------
echo "==> 检查签名身份"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  echo "钥匙串里没有可用于代码签名的「${SIGN_ID}」" >&2
  echo "换身份用 CODESIGN_IDENTITY=\"<证书名>\"；没有证书就别发版（换签名会让老用户重新授权）" >&2
  exit 1
fi

# ---------- Sparkle ----------
SPARKLE_DIR="$("$ROOT/scripts/fetch-sparkle.sh")"
export SPARKLE_DIR

# ---------- 构建（隔离目录，不碰 dist/） ----------
echo "==> 构建 $APP_NAME ${VERSION}（通用二进制，落 release/stage，dist/ 不动）"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# 发布产物一律 arm64 + x86_64：README 承诺「macOS 26+」，Intel Mac 用户也要能打开
DIST_DIR="$STAGE" CODESIGN_IDENTITY="$SIGN_ID" ./build.sh --universal

APP="$STAGE/$APP_NAME.app"
codesign --verify --deep --strict "$APP"
SIGNED_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ "$SIGNED_ID" = "$SIGN_ID" ] || {
  echo "签名身份对不上：期望「${SIGN_ID}」，实际「${SIGNED_ID:-（无）}」" >&2
  exit 1
}

# ---------- 组装 DMG 内容 ----------
echo "==> 组装 DMG"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'EOF'
耳录 EarShot —— 下载解压后把 EarShot.app 拖进左边的「应用程序」。

系统要求：macOS 26 或更新。

首次打开如果被系统拦下（本应用未做 Apple 公证），右键点图标 →
打开 → 再点一次「打开」，只需要这一次。
首次开听前会要「录制电脑音频」和「麦克风」权限，应用里会一步步提示。

装好后会自动检查更新：发现新版会弹窗，确认后下载并安装。
（也可以用菜单里的「检查更新…」手动检查。）

校验下载完整性：
  shasum -a 256 -c EarShot-<版本>.dmg.sha256
EOF

# ---------- 打包 ----------
echo "==> hdiutil 打包"
hdiutil create -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
hdiutil verify "$DMG" >/dev/null
(cd "$RELEASE_DIR" && shasum -a 256 "$APP_NAME-$VERSION.dmg" > "$APP_NAME-$VERSION.dmg.sha256")

# ---------- appcast ----------
echo "==> 生成 appcast"
APPDIR="$(mktemp -d "${TMPDIR:-/tmp}/earshot-appcast.XXXXXX")"
trap 'rm -rf "$APPDIR"' EXIT
cp "$DMG" "$APPDIR/"
# 只放当前版本：旧 DMG 在目录里才会生成 delta，发布我们不传 delta
"$SPARKLE_DIR/bin/generate_appcast" \
  --download-url-prefix "$RELEASE_URL/download/$TAG/" \
  "$APPDIR"
cp "$APPDIR/appcast.xml" "$APPCAST"
grep -Fq 'sparkle:edSignature=' "$APPCAST" || { echo "appcast 没签名" >&2; exit 1; }
grep -Fq "/download/$TAG/$APP_NAME-$VERSION.dmg" "$APPCAST" || {
  echo "appcast 里的下载地址不对" >&2
  exit 1
}

echo
echo "==> 完成"
echo "    DMG    $DMG  ($(du -h "$DMG" | cut -f1))"
echo "    校验   $(cat "$SHA")"
echo "    内容   EarShot.app + /Applications 软链 + 安装说明.txt"
echo "    签名   ${SIGN_ID}（自签，未公证）—— 别的机器首次打开要右键→打开"
echo "    清单   $APPCAST"
echo "    更新源 ${FEED_URL}（发布后生效）"

# ---------- 发布（可选） ----------
if [ "$PUBLISH" = "1" ]; then
  echo
  echo "==> 发 GitHub Release $TAG"
  git tag -a "$TAG" -m "$APP_NAME $VERSION"
  git push origin "$TAG"
  # 先 draft 上传全部资产，成功了再切正式；避免半发布的 latest 被客户端读到
  gh release create "$TAG" "$DMG" "$SHA" "$APPCAST" \
    --title "$APP_NAME $VERSION" --generate-notes --draft --verify-tag
  gh release edit "$TAG" --draft=false --latest
  echo "    已发布：$(gh release view "$TAG" --json url -q .url)"
  echo "    更新源：${FEED_URL}"
fi
