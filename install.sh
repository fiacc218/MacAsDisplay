#!/usr/bin/env bash
# MacAsDisplay Receiver — 老 Mac 一行安装脚本。
#
# 用法(在老 Mac 的 Terminal 里):
#     curl -fsSL https://raw.githubusercontent.com/fiacc218/MacAsDisplay/main/install.sh | sh
#
# 做什么:
#   1. 从 GitHub Releases 拉最新 MacAsDisplayReceiver.zip (Universal 二进制)
#   2. 解 macOS quarantine 属性 (这是关键,否则 Gatekeeper 拦)
#   3. ad-hoc 本地重签(TCC 绑定本机身份,后续更新 rebuild 会要重授权 —— alpha 阶段接受)
#   4. 搬到 /Applications/
#   5. 启动
#
# 不需要: Xcode / xcodegen / git clone / Apple 开发者账号 / ssh 配置。
# 源码可审: 这个文件就在 repo 根,50 行,随便读。

set -euo pipefail

REPO="${MACASDISPLAY_REPO:-fiacc218/MacAsDisplay}"
APP_NAME="MacAsDisplayReceiver.app"
ZIP_NAME="MacAsDisplayReceiver.zip"
INSTALL_DIR="${MACASDISPLAY_INSTALL_DIR:-/Applications}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "只支持 macOS。"

log "查询最新 Release..."
LATEST_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o "\"browser_download_url\": *\"[^\"]*$ZIP_NAME\"" \
    | head -1 | cut -d'"' -f4)
[[ -n "$LATEST_URL" ]] || die "找不到 $ZIP_NAME (repo=$REPO)。可能还没发第一个 Release。"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "下载 $LATEST_URL"
curl -fL --progress-bar "$LATEST_URL" -o "$TMP/$ZIP_NAME"

log "解压..."
( cd "$TMP" && /usr/bin/unzip -q "$ZIP_NAME" )
APP_SRC=$(find "$TMP" -maxdepth 3 -name "$APP_NAME" -type d | head -1)
[[ -n "$APP_SRC" ]] || die "压缩包里没找到 $APP_NAME。"

log "解除 quarantine + ad-hoc 重签..."
/usr/bin/xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_SRC" >/dev/null

DEST="$INSTALL_DIR/$APP_NAME"
if [[ -d "$DEST" ]]; then
    log "替换已有版本: $DEST"
    /usr/bin/pkill -x MacAsDisplayReceiver 2>/dev/null || true
    sleep 0.3
    rm -rf "$DEST"
fi

log "安装到 $DEST"
# /Applications 通常 user 可写;必要时 sudo
if ! mv "$APP_SRC" "$INSTALL_DIR/" 2>/dev/null; then
    log "需要 sudo 写入 $INSTALL_DIR"
    sudo mv "$APP_SRC" "$INSTALL_DIR/"
fi

log "启动 Receiver..."
/usr/bin/open "$DEST"

cat <<EOF

✓ Receiver 已安装并启动。
  位置:  $DEST
  下一步:
    1. 首次启动会弹 "本地网络" 授权,点 Allow。
    2. 按 ESC 可退出全屏。
    3. 从 Sender 机器复制 PSK 到本机: scp ~/.config/macasdisplay/psk $USER@$(hostname -s):~/.config/macasdisplay/
       (第一次启动会自动生成 PSK 到 ~/.config/macasdisplay/psk,两端必须一致)

EOF
