#!/bin/sh
# Lightweight VLESS + REALITY installer for fresh NAT VPS machines.
# Run on the VPS: sh install-reality.sh
set -eu
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

APP=/opt/reality-nat
SERVICE=reality-nat
VERSION=${XRAY_VERSION:-v26.10.31}
WORK=
LOCK=
OWN_APP=0
OWN_SERVICE=0
OWN_USER=0
OWN_GROUP=0
SUCCESS=0
INIT=

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
help() {
    cat <<'EOF'
用法：以 root 在待部署的 VPS 上运行 sh install-reality.sh
支持：Alpine + OpenRC；Debian/Ubuntu + systemd；x86_64/aarch64。
交互填写公网 IPv4/域名、NAT 公网 TCP 端口、内部监听端口、SNI。
脚本不会创建商家 NAT 映射，也不会修改防火墙、SSH、swap 或内核参数。

无交互示例（替换地址和端口）：
  PUBLIC_HOST=your-nat.example.com PUBLIC_PORT=20443 LISTEN_PORT=443 \
    SNI=www.tesla.cn sh install-reality.sh

默认 SNI：www.tesla.cn（沿用原部署，可自行更换）。
默认 Xray：v26.10.31；可用 XRAY_VERSION=vX.Y.Z 指定官方版本。
已安装本脚本的节点：sh install-reality.sh --show
发现已有 Xray 配置/服务会退出；本脚本不负责覆盖、迁移或升级。
EOF
}
valid_port() {
    case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}
valid_host() {
    [ "${#1}" -le 253 ] || return 1
    case "$1" in ''|*[!a-zA-Z0-9.-]*|.*|*.|-*|*-|*..*|*.-*|*-.*) return 1 ;; esac
    # IPv6 literals are deliberately excluded; use a DNS name for IPv6.
    printf '%s\n' "$1" | awk -F. '
        { for (i=1;i<=NF;i++) if (length($i)>63) exit 1
          if ($0 ~ /^[0-9.]+$/) {
            if (NF != 4) exit 1
            for (i=1;i<=NF;i++) if ($i>255 || (length($i)>1 && $i ~ /^0/)) exit 1
          }
        }'
}
ask() {
    printf '%s' "$1" >&2
    IFS= read -r ANSWER || die '未读到输入；请交互运行或设置上述环境变量。'
}
inputs() {
    if [ -z "${PUBLIC_HOST:-}" ]; then
        ask '公网入口 IPv4 或域名（商家提供，不是机器内网 IP）：'
        PUBLIC_HOST=$ANSWER
    fi
    valid_host "$PUBLIC_HOST" || die '公网地址不合法；填写纯 IPv4/域名，不要带协议、端口或路径。'
    if [ -z "${PUBLIC_PORT:-}" ]; then
        ask '商家分配的公网 TCP 端口（例如 20443）：'
        PUBLIC_PORT=$ANSWER
    fi
    valid_port "$PUBLIC_PORT" || die '公网端口必须是 1–65535，不能带前导零。'
    if [ -z "${LISTEN_PORT:-}" ]; then
        if [ -t 0 ]; then
            ask 'NAT 映射到的内部端口 [443]：'
            LISTEN_PORT=${ANSWER:-443}
        else LISTEN_PORT=443; fi
    fi
    valid_port "$LISTEN_PORT" || die '内部端口必须是 1–65535，不能带前导零。'
    if [ -z "${SNI:-}" ]; then
        if [ -t 0 ]; then
            ask 'REALITY 伪装域名 [www.tesla.cn]：'
            SNI=${ANSWER:-www.tesla.cn}
        else SNI=www.tesla.cn; fi
    fi
    valid_host "$SNI" || die 'SNI 不合法；填写纯域名。'
    case "$SNI" in *[a-zA-Z]*) ;; *) die 'SNI 应填写域名。' ;; esac
    printf '%s\n' "$VERSION" | LC_ALL=C grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die 'XRAY_VERSION 格式应为 vX.Y.Z。'
    say "部署：$PUBLIC_HOST:$PUBLIC_PORT → 本机 TCP $LISTEN_PORT；SNI=$SNI；Xray=$VERSION"
}
preflight() {
    [ "$(id -u)" -eq 0 ] || die '请用 root 运行。'
    [ "$(uname -s)" = Linux ] || die '只支持 Linux。'
    if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
        INIT=openrc
    elif [ -f /etc/debian_version ] && [ -d /run/systemd/system ]; then
        INIT=systemd
    else die '支持 Alpine/OpenRC 或 Debian、Ubuntu/systemd；当前系统不符合。'; fi
    case "$(uname -m)" in
        x86_64) ARCH=64 ;;
        aarch64|arm64) ARCH=arm64-v8a ;;
        *) die '目前仅支持 x86_64 和 aarch64。' ;;
    esac
    for P in "$APP" /etc/init.d/reality-nat /etc/systemd/system/reality-nat.service \
        /usr/local/etc/xray /etc/xray /etc/xray-reality /etc/init.d/xray \
        /etc/systemd/system/xray.service /usr/lib/systemd/system/xray.service \
        /lib/systemd/system/xray.service /etc/systemd/system/xray-reality.service; do
        [ ! -e "$P" ] && [ ! -L "$P" ] || die "发现已有安装：$P。为保护现有节点，停止安装。"
    done
    mkdir /run/reality-nat-install.lock 2>/dev/null || die '安装锁已存在；检查是否有另一个安装进程。'
    LOCK=/run/reality-nat-install.lock
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Downloads go to /var/tmp: /tmp is often a small RAM-backed mount on Alpine.
    mkdir -p /var/tmp
    WORK=$(mktemp -d /var/tmp/reality-nat.XXXXXX)
}
cleanup() {
    CODE=$?
    trap - EXIT
    set +e
    if [ "$SUCCESS" -ne 1 ]; then
        if [ "$OWN_SERVICE" -eq 1 ]; then
            if [ "$INIT" = openrc ]; then
                rc-service "$SERVICE" stop >/dev/null 2>&1 || :
                rc-update del "$SERVICE" default >/dev/null 2>&1 || :
                rm -f /etc/init.d/reality-nat
            else
                systemctl disable --now reality-nat.service >/dev/null 2>&1 || :
                rm -f /etc/systemd/system/reality-nat.service
                systemctl daemon-reload >/dev/null 2>&1 || :
            fi
        fi
        [ "$OWN_APP" -ne 1 ] || rm -rf "$APP"
        if [ "$OWN_USER" -eq 1 ]; then
            if [ "$INIT" = openrc ]; then deluser reality-nat; else userdel reality-nat; fi
        fi
        if [ "$OWN_GROUP" -eq 1 ]; then
            if [ "$INIT" = openrc ]; then delgroup reality-nat; else groupdel reality-nat; fi
        fi
        say '安装未完成；已尝试撤销本次创建的程序、配置、服务和专用用户；已安装的依赖包保留。' >&2
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || :
    exit "$CODE"
}
dependencies() {
    say '安装下载、解压和端口检查工具……'
    if [ "$INIT" = openrc ]; then
        apk add --no-cache ca-certificates curl unzip iproute2
    else
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip iproute2
    fi
    for TOOL in sha256sum od awk ss; do
        command -v "$TOOL" >/dev/null 2>&1 || die "缺少工具：$TOOL"
    done
    ss -H -ltn > "$WORK/listeners"
    if awk -v p="$LISTEN_PORT" '$4 ~ (":" p "$") { found=1 } END { exit !found }' "$WORK/listeners"; then
        die "TCP $LISTEN_PORT 已被占用；未停止现有服务。"
    fi
}
download() {
    FILE="Xray-linux-$ARCH.zip"
    URL="https://github.com/XTLS/Xray-core/releases/download/$VERSION/$FILE"
    say "下载官方 Xray $VERSION 并校验 SHA-256……"
    curl -fSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 600 --retry 3 "$URL" -o "$WORK/xray.zip"
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 --retry 3 "$URL.dgst" -o "$WORK/xray.dgst"
    EXPECTED=$(awk '/SHA(2)?-?256/ { for(i=1;i<=NF;i++) if(length($i)==64 && $i !~ /[^0-9a-fA-F]/) { print tolower($i); exit } }' "$WORK/xray.dgst")
    [ "${#EXPECTED}" -eq 64 ] || die '无法读取官方 SHA-256；不会跳过校验。'
    ACTUAL=$(sha256sum "$WORK/xray.zip" | awk '{print $1}')
    [ "$EXPECTED" = "$ACTUAL" ] || die '下载文件 SHA-256 不匹配。'
    # Only extract the executable. No geoip/geosite database or panel needed.
    unzip -p "$WORK/xray.zip" xray > "$WORK/xray"
    chmod 755 "$WORK/xray"
    "$WORK/xray" version
}
credentials() {
    UUID=$("$WORK/xray" uuid)
    KEYS=$("$WORK/xray" x25519)
    PRIVATE=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /^private[ ]?key$/ {print $2}')
    PUBLIC=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /^(public[ ]?key|password|password \(publickey\))$/ {print $2}')
    for KEY in "$PRIVATE" "$PUBLIC"; do
        [ "${#KEY}" -eq 43 ] || die '无法解析 X25519 密钥。'
        case "$KEY" in *[!a-zA-Z0-9_-]*) die '密钥格式不合法。' ;; esac
    done
    printf '%s\n' "$UUID" | LC_ALL=C grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || die 'UUID 生成失败。'
    SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#SHORT_ID}" -eq 16 ] || die 'shortId 生成失败。'
    unset KEYS KEY
}
render_config() {
    cat <<EOF
{
  "log": {"access": "none", "loglevel": "warning"},
  "inbounds": [{
    "tag": "reality-in", "listen": "0.0.0.0", "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "target": "$SNI:443", "xver": 0,
        "serverNames": ["$SNI"], "privateKey": "$PRIVATE", "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
}
render_openrc() {
    cat <<'EOF'
#!/sbin/openrc-run
description="Lightweight VLESS REALITY NAT node"
supervisor="supervise-daemon"
command="/opt/reality-nat/xray"
command_args="run -config /opt/reality-nat/config.json"
command_user="reality-nat:reality-nat"
capabilities="^cap_net_bind_service"
pidfile="/run/reality-nat.pid"
respawn_delay=5
respawn_max=5
respawn_period=60
output_logger="logger -t reality-nat"
error_logger="logger -t reality-nat"
export GOMEMLIMIT=32MiB
export GOGC=50
depend() { need net; use dns logger; }
checkconfig() { "$command" run -test -config /opt/reality-nat/config.json; }
start_pre() { checkconfig; }
stop_pre() { if [ "$RC_CMD" = restart ]; then checkconfig; fi; }
EOF
}
render_systemd() {
    cat <<'EOF'
[Unit]
Description=Lightweight VLESS REALITY NAT node
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=reality-nat
Group=reality-nat
ExecStartPre=/opt/reality-nat/xray run -test -config /opt/reality-nat/config.json
ExecStart=/opt/reality-nat/xray run -config /opt/reality-nat/config.json
Restart=on-failure
RestartSec=5
Environment=GOMEMLIMIT=32MiB
Environment=GOGC=50
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}
install_files() {
    render_config > "$WORK/config.json"
    "$WORK/xray" run -test -config "$WORK/config.json"
    if id reality-nat >/dev/null 2>&1; then
        die '专用用户 reality-nat 已存在；请检查是否有旧安装残留。'
    fi
    if [ "$INIT" = openrc ]; then
        addgroup -S reality-nat
        OWN_GROUP=1
        adduser -S -D -H -s /sbin/nologin -G reality-nat reality-nat
    else
        useradd --system --user-group --no-create-home --shell /usr/sbin/nologin reality-nat
        OWN_GROUP=1
    fi
    OWN_USER=1
    mkdir "$APP"
    OWN_APP=1
    chmod 750 "$APP"
    chown root:reality-nat "$APP"
    cp "$WORK/xray" "$APP/xray"
    chmod 755 "$APP/xray"
    cp "$WORK/config.json" "$APP/config.json"
    chown root:reality-nat "$APP/config.json"
    chmod 640 "$APP/config.json"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#NAT-REALITY\n' \
        "$UUID" "$PUBLIC_HOST" "$PUBLIC_PORT" "$SNI" "$PUBLIC" "$SHORT_ID" > "$APP/client.txt"
    chmod 600 "$APP/client.txt"
    printf '%s\n' "$VERSION" > "$APP/version"
    OWN_SERVICE=1
    if [ "$INIT" = openrc ]; then
        render_openrc > /etc/init.d/reality-nat
        chmod 755 /etc/init.d/reality-nat
        rc-service reality-nat start
        rc-update add reality-nat default
    else
        render_systemd > /etc/systemd/system/reality-nat.service
        chmod 644 /etc/systemd/system/reality-nat.service
        systemctl daemon-reload
        systemctl enable --now reality-nat.service
    fi
}
verify() {
    sleep 2
    if [ "$INIT" = openrc ]; then rc-service reality-nat status
    else systemctl is-active --quiet reality-nat.service; fi
    ss -H -ltnp > "$WORK/listeners"
    awk -v p="$LISTEN_PORT" '$4 ~ (":" p "$") && /xray/ { found=1 } END { exit !found }' "$WORK/listeners" || die '未检测到 Xray 监听目标端口。'
    SUCCESS=1
    say ''
    say '安装完成：配置检查、服务启动和本机 TCP 监听检查通过。'
    say "请确认商家面板已有 TCP $PUBLIC_PORT → 本机 $LISTEN_PORT 的映射，系统防火墙允许内部端口。"
    say '公网 NAT 映射和 REALITY 实际连接仍需从外部客户端验证。'
    say '导入链接（已保存到 /opt/reality-nat/client.txt）：'
    cat "$APP/client.txt"
    say '32MiB 是 Go 运行时软内存目标，不是进程总内存上限。'
    if [ "$INIT" = openrc ]; then
        say '管理：rc-service reality-nat status|restart|stop；日志：logread -e reality-nat 或 /var/log/messages'
    else
        say '管理：systemctl status|restart|stop reality-nat；日志：journalctl -u reality-nat -n 50'
    fi
}
main() {
    case "${1:-}" in
        -h|--help) help; return ;;
        --show) [ "$(id -u)" -eq 0 ] || die '请用 root 运行。'; cat "$APP/client.txt"; return ;;
        '') ;;
        *) help; exit 1 ;;
    esac
    preflight
    inputs
    dependencies
    download
    credentials
    install_files
    verify
}
main "$@"
