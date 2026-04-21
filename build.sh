#!/usr/bin/env bash
# MacAsDisplay 一键构建脚本。用法:
#   ./build.sh sender              # 本机构建 Sender
#   ./build.sh receiver            # 构建 Receiver (Apple Silicon 上自动交叉编译 x86_64)
#   ./build.sh all                 # 两个都构建
#   ./build.sh deploy user@host    # 构建 Receiver 并 rsync 到远端,自动启动
#   ./build.sh clean               # 清掉 build/ 和 .xcodeproj
#
# 环境变量:
#   CONFIG=Release  切到 Release 配置(默认 Debug)
#   RECEIVER_ARCH=arm64  强制 Receiver 架构(默认:本机 arm64 时交叉编译 x86_64)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"
DERIVED="$ROOT/build"
SENDER_APP="$DERIVED/Build/Products/$CONFIG/MacAsDisplaySender.app"
RECEIVER_APP="$DERIVED/Build/Products/$CONFIG/MacAsDisplayReceiver.app"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

ensure_xcodegen() {
    command -v xcodegen >/dev/null 2>&1 || die "缺 xcodegen: brew install xcodegen"
}

ensure_project() {
    ensure_xcodegen
    # Config.xcconfig gitignored(放本地签名身份)。project.yml 硬引用它,不存在时
    # xcodegen 会校验失败。留个空文件 → fall through 到 xcodebuild 命令行/默认 ad-hoc。
    [[ -f Config.xcconfig ]] || touch Config.xcconfig
    if [[ ! -d MacAsDisplay.xcodeproj ]] || [[ project.yml -nt MacAsDisplay.xcodeproj ]]; then
        log "xcodegen generate"
        xcodegen generate --quiet
    fi
}

build_scheme() {
    local scheme="$1"; shift
    ensure_project
    log "xcodebuild $scheme ($CONFIG)"
    xcodebuild \
        -scheme "$scheme" \
        -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED" \
        "$@" \
        build | xcbeautify 2>/dev/null || \
    xcodebuild \
        -scheme "$scheme" \
        -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED" \
        "$@" \
        build
}

cmd_sender() {
    build_scheme Sender
    log "Sender → $SENDER_APP"
}

cmd_receiver() {
    local arch="${RECEIVER_ARCH:-}"
    if [[ -z "$arch" ]]; then
        # 本机是 arm64 → 默认交叉编译 x86_64(老 Intel Mac)
        # 本机是 x86_64 → 本机 build
        if [[ "$(uname -m)" == "arm64" ]]; then arch="x86_64"; else arch="x86_64"; fi
    fi
    build_scheme Receiver -arch "$arch" ONLY_ACTIVE_ARCH=NO
    log "Receiver ($arch) → $RECEIVER_APP"
}

cmd_all() {
    cmd_sender
    cmd_receiver
}

cmd_deploy() {
    local target="${1:-}"
    [[ -z "$target" ]] && die "用法: ./build.sh deploy user@host[:/remote/path]"

    local remote_host="${target%%:*}"
    local remote_path="/Applications"
    if [[ "$target" == *:* ]]; then remote_path="${target#*:}"; fi

    log "preflight: ssh $remote_host"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" true 2>/dev/null; then
        die "ssh $remote_host 失败。请在旧 Mac 上开启:
  系统设置 → 通用 → 共享 → 远程登录 (Remote Login)
并确保本机能 ssh $remote_host(已加 key 或能免密登录)。"
    fi

    cmd_receiver

    log "rsync → $remote_host:$remote_path/"
    rsync -az --delete "$RECEIVER_APP" "$remote_host:$remote_path/"

    log "remote: codesign + open"
    ssh "$remote_host" bash -s "$remote_path" <<'REMOTE'
set -e
REMOTE_PATH="$1"
APP="$REMOTE_PATH/MacAsDisplayReceiver.app"
# ad-hoc 重签,避免跨机 quarantine
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
pkill -x MacAsDisplayReceiver 2>/dev/null || true
open "$APP"
REMOTE
    log "done. Receiver 已在 $remote_host 启动"
}

cmd_clean() {
    log "rm -rf build/ MacAsDisplay.xcodeproj"
    rm -rf "$DERIVED" MacAsDisplay.xcodeproj
}

cmd="${1:-}"
case "$cmd" in
    sender)   shift; cmd_sender   "$@" ;;
    receiver) shift; cmd_receiver "$@" ;;
    all)      shift; cmd_all      "$@" ;;
    deploy)   shift; cmd_deploy   "$@" ;;
    clean)    shift; cmd_clean    "$@" ;;
    ""|-h|--help)
        sed -n '2,12p' "$0" | sed 's/^# //;s/^#//'
        ;;
    *) die "未知命令: $cmd (试 ./build.sh --help)" ;;
esac
