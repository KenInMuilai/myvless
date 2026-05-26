#!/bin/sh

set -e

# ============================================================
# VLESS + Reality 一键安装脚本
# System: Alpine Linux 3.21
# Core: Xray-core
# Service Manager: OpenRC
# Shortcut: v
# ============================================================

XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG_FILE="/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SERVICE="/etc/init.d/xray"
NODE_ENV_FILE="/etc/xray/node.env"
SHORTCUT_BIN="/usr/local/bin/v"

DEFAULT_REALITY_DEST="music.apple.com:443"
DEFAULT_REALITY_SNI="music.apple.com"

echo "============================================================"
echo " VLESS + Reality Installer for Alpine Linux"
echo "============================================================"
echo

if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 用户运行此脚本"
    exit 1
fi

check_alpine() {
    if [ ! -f /etc/alpine-release ]; then
        echo "警告：当前系统似乎不是 Alpine Linux"
        echo "脚本仍会继续执行，但不保证兼容"
        echo
    fi
}

install_dependencies() {
    echo "[1/8] 安装依赖..."

    apk update
    apk add --no-cache \
        curl \
        unzip \
        ca-certificates \
        openssl \
        tzdata \
        net-tools \
        iproute2

    echo "依赖安装完成"
    echo
}

detect_arch() {
    echo "[2/8] 检测系统架构..."

    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64)
            XRAY_ARCH="64"
            ;;
        aarch64)
            XRAY_ARCH="arm64-v8a"
            ;;
        armv7l)
            XRAY_ARCH="arm32-v7a"
            ;;
        armv6l)
            XRAY_ARCH="arm32-v6"
            ;;
        i386|i686)
            XRAY_ARCH="32"
            ;;
        *)
            echo "错误：暂不支持的系统架构：$ARCH"
            exit 1
            ;;
    esac

    echo "当前架构：$ARCH"
    echo "Xray 架构：$XRAY_ARCH"
    echo
}

random_high_port() {
    PORT_NUM="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    PORT="$((PORT_NUM % 10000 + 50000))"
    echo "$PORT"
}

get_default_ip() {
    DEFAULT_IP=""

    DEFAULT_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"

    if [ -z "$DEFAULT_IP" ]; then
        DEFAULT_IP="$(curl -4 -fsS https://ifconfig.me 2>/dev/null || true)"
    fi

    if [ -z "$DEFAULT_IP" ]; then
        DEFAULT_IP="$(curl -4 -fsS https://ip.sb 2>/dev/null || true)"
    fi

    if [ -z "$DEFAULT_IP" ] && command -v ip >/dev/null 2>&1; then
        DEFAULT_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
    fi

    echo "$DEFAULT_IP"
}

format_vless_host() {
    HOST="$1"

    case "$HOST" in
        *:*)
            echo "[$HOST]"
            ;;
        *)
            echo "$HOST"
            ;;
    esac
}

read_config() {
    echo "[3/8] 配置节点参数..."
    echo

    AUTO_PUBLIC_HOST="$(get_default_ip)"

    if [ -n "$AUTO_PUBLIC_HOST" ]; then
        printf "请输入公网 IP 或域名，直接回车默认 [%s]: " "$AUTO_PUBLIC_HOST"
    else
        printf "请输入公网 IP 或域名: "
    fi

    read -r PUBLIC_HOST
    PUBLIC_HOST="${PUBLIC_HOST:-$AUTO_PUBLIC_HOST}"

    if [ -z "$PUBLIC_HOST" ]; then
        echo "错误：无法自动获取公网 IP，请手动输入公网 IP 或域名"
        exit 1
    fi

    RANDOM_PORT="$(random_high_port)"

    printf "请输入公网端口，直接回车随机高位端口 [%s]: " "$RANDOM_PORT"
    read -r PUBLIC_PORT
    PUBLIC_PORT="${PUBLIC_PORT:-$RANDOM_PORT}"

    printf "请输入本机监听端口，直接回车使用公网端口 [%s]: " "$PUBLIC_PORT"
    read -r LISTEN_PORT
    LISTEN_PORT="${LISTEN_PORT:-$PUBLIC_PORT}"

    echo
    echo "Reality Target/dest 默认：${DEFAULT_REALITY_DEST}"
    printf "请输入 Reality Target/dest，直接回车默认 [%s]: " "$DEFAULT_REALITY_DEST"
    read -r REALITY_DEST
    REALITY_DEST="${REALITY_DEST:-$DEFAULT_REALITY_DEST}"

    echo
    echo "Reality SNI 默认：${DEFAULT_REALITY_SNI}"
    printf "请输入 Reality SNI，直接回车默认 [%s]: " "$DEFAULT_REALITY_SNI"
    read -r REALITY_SNI
    REALITY_SNI="${REALITY_SNI:-$DEFAULT_REALITY_SNI}"

    echo
}

install_xray() {
    echo "[4/8] 下载并安装 Xray-core..."

    TMP_DIR="$(mktemp -d)"
    cd "$TMP_DIR"

    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

    echo "下载地址：$XRAY_URL"

    curl -L -o xray.zip "$XRAY_URL"
    unzip -q xray.zip

    if [ ! -f xray ]; then
        echo "错误：Xray 下载或解压失败"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    install -m 755 xray "$XRAY_BIN"

    mkdir -p /usr/local/share/xray

    if [ -f geoip.dat ]; then
        install -m 644 geoip.dat /usr/local/share/xray/geoip.dat
    fi

    if [ -f geosite.dat ]; then
        install -m 644 geosite.dat /usr/local/share/xray/geosite.dat
    fi

    cd /
    rm -rf "$TMP_DIR"

    echo "Xray 安装完成"
    echo
}

generate_config() {
    echo "[5/8] 生成 VLESS + Reality 配置..."

    mkdir -p "$XRAY_CONFIG_DIR"
    mkdir -p "$XRAY_LOG_DIR"

    UUID="$("$XRAY_BIN" uuid)"

    KEYS="$("$XRAY_BIN" x25519 2>/dev/null || true)"

    PRIVATE_KEY="$(printf "%s\n" "$KEYS" | sed -n 's/^Private key:[[:space:]]*//p' | head -n 1)"
    PUBLIC_KEY="$(printf "%s\n" "$KEYS" | sed -n 's/^Public key:[[:space:]]*//p' | head -n 1)"

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "错误：Reality 密钥生成失败"
        echo
        echo "Xray x25519 输出内容："
        echo "$KEYS"
        echo
        echo "请检查 Xray 是否正常："
        echo "$XRAY_BIN version"
        exit 1
    fi

    SHORT_ID="$(openssl rand -hex 8)"

    cat > "$XRAY_CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

    LINK_HOST="$(format_vless_host "$PUBLIC_HOST")"

    VLESS_LINK="vless://${UUID}@${LINK_HOST}:${PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality"

    cat > "$NODE_ENV_FILE" <<EOF
PUBLIC_HOST="${PUBLIC_HOST}"
PUBLIC_PORT="${PUBLIC_PORT}"
LISTEN_PORT="${LISTEN_PORT}"
UUID="${UUID}"
FLOW="xtls-rprx-vision"
NETWORK="tcp"
SECURITY="reality"
REALITY_DEST="${REALITY_DEST}"
REALITY_SNI="${REALITY_SNI}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
FINGERPRINT="chrome"
VLESS_LINK="${VLESS_LINK}"
EOF

    chmod 600 "$NODE_ENV_FILE"

    echo "配置文件已生成：$XRAY_CONFIG_FILE"
    echo "节点信息已保存：$NODE_ENV_FILE"
    echo
    echo "Reality PrivateKey: ${PRIVATE_KEY}"
    echo "Reality PublicKey : ${PUBLIC_KEY}"
    echo "Reality ShortID   : ${SHORT_ID}"
    echo
}

install_service() {
    echo "[6/8] 配置 OpenRC 服务..."

    cat > "$XRAY_SERVICE" <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service"

command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG_FILE}"
command_background="yes"

pidfile="/run/xray.pid"

depend() {
    need net
    after firewall
}
EOF

    chmod +x "$XRAY_SERVICE"

    rc-update add xray default >/dev/null 2>&1 || true
    rc-service xray restart

    echo "Xray 服务已启动"
    echo
}

install_shortcut() {
    echo "[7/8] 安装快捷命令 v..."

    cat > "$SHORTCUT_BIN" <<'EOF'
#!/bin/sh

NODE_ENV_FILE="/etc/xray/node.env"
XRAY_CONFIG_FILE="/etc/xray/config.json"
XRAY_LOG_DIR="/var/log/xray"

if [ ! -f "$NODE_ENV_FILE" ]; then
    echo "未找到节点信息文件：$NODE_ENV_FILE"
    echo "请先运行安装脚本。"
    exit 1
fi

. "$NODE_ENV_FILE"

pause_return() {
    echo
    printf "按回车返回菜单..."
    read -r _
}

show_info() {
    clear
    echo "============================================================"
    echo " VLESS + Reality 节点信息"
    echo "============================================================"
    echo
    echo "地址 Host          : ${PUBLIC_HOST}"
    echo "公网端口 Port      : ${PUBLIC_PORT}"
    echo "本机监听端口       : ${LISTEN_PORT}"
    echo "UUID               : ${UUID}"
    echo "Flow               : ${FLOW}"
    echo "Network            : ${NETWORK}"
    echo "Security           : ${SECURITY}"
    echo "Reality Target     : ${REALITY_DEST}"
    echo "Reality SNI        : ${REALITY_SNI}"
    echo "Reality PublicKey  : ${PUBLIC_KEY}"
    echo "Reality ShortID    : ${SHORT_ID}"
    echo "Fingerprint        : ${FINGERPRINT}"
    echo
    echo "============================================================"
    echo " 节点链接"
    echo "============================================================"
    echo
    echo "${VLESS_LINK}"
    echo
}

while true
do
    show_info

    echo "============================================================"
    echo " 管理菜单"
    echo "============================================================"
    echo
    echo " 1. 查看 Xray 状态"
    echo " 2. 启动 Xray"
    echo " 3. 停止 Xray"
    echo " 4. 重启 Xray"
    echo " 5. 查看端口监听"
    echo " 6. 查看错误日志"
    echo " 7. 查看配置文件"
    echo " 8. 查看节点链接"
    echo " 0. 退出"
    echo
    printf "请选择: "
    read -r CHOICE

    case "$CHOICE" in
        1)
            rc-service xray status
            pause_return
            ;;
        2)
            rc-service xray start
            pause_return
            ;;
        3)
            rc-service xray stop
            pause_return
            ;;
        4)
            rc-service xray restart
            pause_return
            ;;
        5)
            netstat -lntp | grep xray || true
            pause_return
            ;;
        6)
            tail -n 80 "${XRAY_LOG_DIR}/error.log" || true
            pause_return
            ;;
        7)
            cat "$XRAY_CONFIG_FILE"
            pause_return
            ;;
        8)
            echo
            echo "${VLESS_LINK}"
            pause_return
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选择"
            pause_return
            ;;
    esac
done
EOF

    chmod +x "$SHORTCUT_BIN"

    echo "快捷命令安装完成，以后输入 v 即可呼出节点信息"
    echo
}

show_result() {
    echo "[8/8] 安装完成"
    echo

    echo "============================================================"
    echo " VLESS + Reality 节点信息"
    echo "============================================================"
    echo
    echo "地址 Host          : ${PUBLIC_HOST}"
    echo "公网端口 Port      : ${PUBLIC_PORT}"
    echo "本机监听端口       : ${LISTEN_PORT}"
    echo "UUID               : ${UUID}"
    echo "Flow               : xtls-rprx-vision"
    echo "Network            : tcp"
    echo "Security           : reality"
    echo "Reality Target     : ${REALITY_DEST}"
    echo "Reality SNI        : ${REALITY_SNI}"
    echo "Reality PublicKey  : ${PUBLIC_KEY}"
    echo "Reality ShortID    : ${SHORT_ID}"
    echo "Fingerprint        : chrome"
    echo
    echo "============================================================"
    echo " 节点链接"
    echo "============================================================"
    echo
    echo "${VLESS_LINK}"
    echo
    echo "============================================================"
    echo " 快捷命令"
    echo "============================================================"
    echo
    echo "以后输入下面命令即可呼出节点信息和管理菜单："
    echo
    echo "  v"
    echo
    echo "============================================================"
    echo " 常用命令"
    echo "============================================================"
    echo
    echo "启动：rc-service xray start"
    echo "停止：rc-service xray stop"
    echo "重启：rc-service xray restart"
    echo "状态：rc-service xray status"
    echo "配置：${XRAY_CONFIG_FILE}"
    echo "日志：${XRAY_LOG_DIR}/error.log"
    echo
    echo "============================================================"
    echo " NAT 机器提醒"
    echo "============================================================"
    echo
    echo "如果你是 NAT 机器，请确认服务商后台 TCP 端口转发："
    echo
    echo "公网 IP:${PUBLIC_PORT}  ->  本机内网 IP:${LISTEN_PORT}"
    echo
    echo "注意：脚本自动获取的是出口公网 IP，但 NAT 机器必须有端口映射才能连接。"
    echo
}

main() {
    check_alpine
    install_dependencies
    detect_arch
    read_config
    install_xray
    generate_config
    install_service
    install_shortcut
    show_result
}

main "$@"
