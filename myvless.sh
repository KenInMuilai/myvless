#!/bin/sh

set -e

# ============================================================
# VLESS + Reality 一键安装脚本
# System: Alpine Linux 3.21
# Core: Xray-core
# Service Manager: OpenRC
# ============================================================

XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG_FILE="/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SERVICE="/etc/init.d/xray"

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
    echo "[1/7] 安装依赖..."

    apk update
    apk add --no-cache \
        curl \
        unzip \
        ca-certificates \
        openssl \
        tzdata \
        net-tools

    echo "依赖安装完成"
    echo
}

detect_arch() {
    echo "[2/7] 检测系统架构..."

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

read_config() {
    echo "[3/7] 配置节点参数..."
    echo

    read -r -p "请输入公网 IP 或域名: " PUBLIC_HOST
    read -r -p "请输入客户端连接的公网端口: " PUBLIC_PORT
    read -r -p "请输入本机监听端口，NAT 机器一般填写内网映射端口: " LISTEN_PORT

    if [ -z "$PUBLIC_HOST" ]; then
        echo "错误：公网 IP 或域名不能为空"
        exit 1
    fi

    if [ -z "$PUBLIC_PORT" ]; then
        echo "错误：公网端口不能为空"
        exit 1
    fi

    if [ -z "$LISTEN_PORT" ]; then
        echo "错误：监听端口不能为空"
        exit 1
    fi

    echo
    echo "Reality 伪装目标用于 TLS 握手回落。"
    echo "建议使用真实存在且支持 TLS 1.3 的网站。"
    echo "默认使用：www.microsoft.com:443"
    echo

    read -r -p "请输入 Reality dest，回车默认 www.microsoft.com:443: " REALITY_DEST
    REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"

    DEFAULT_SNI="$(echo "$REALITY_DEST" | cut -d ':' -f 1)"

    read -r -p "请输入 Reality SNI，回车默认 ${DEFAULT_SNI}: " REALITY_SNI
    REALITY_SNI="${REALITY_SNI:-$DEFAULT_SNI}"

    echo
}

install_xray() {
    echo "[4/7] 下载并安装 Xray-core..."

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
    echo "[5/7] 生成 VLESS + Reality 配置..."

    mkdir -p "$XRAY_CONFIG_DIR"
    mkdir -p "$XRAY_LOG_DIR"

    UUID="$("$XRAY_BIN" uuid)"

    KEYS="$("$XRAY_BIN" x25519)"
    PRIVATE_KEY="$(echo "$KEYS" | awk '/Private key:/ {print $3}')"
    PUBLIC_KEY="$(echo "$KEYS" | awk '/Public key:/ {print $3}')"

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

    echo "配置文件已生成：$XRAY_CONFIG_FILE"
    echo
}

install_service() {
    echo "[6/7] 配置 OpenRC 服务..."

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

show_result() {
    echo "[7/7] 安装完成"
    echo

    VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:${PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Alpine-Reality"

    echo "============================================================"
    echo " VLESS + Reality 节点信息"
    echo "============================================================"
    echo
    echo "地址 Host       : ${PUBLIC_HOST}"
    echo "公网端口 Port   : ${PUBLIC_PORT}"
    echo "本机监听端口    : ${LISTEN_PORT}"
    echo "UUID            : ${UUID}"
    echo "Flow            : xtls-rprx-vision"
    echo "Network         : tcp"
    echo "Security        : reality"
    echo "Reality SNI     : ${REALITY_SNI}"
    echo "Reality Dest    : ${REALITY_DEST}"
    echo "Reality PublicKey : ${PUBLIC_KEY}"
    echo "Reality ShortID   : ${SHORT_ID}"
    echo "Fingerprint     : chrome"
    echo
    echo "============================================================"
    echo " 节点链接"
    echo "============================================================"
    echo
    echo "${VLESS_LINK}"
    echo
    echo "============================================================"
    echo " 常用命令"
    echo "============================================================"
    echo
    echo "启动 Xray："
    echo "  rc-service xray start"
    echo
    echo "停止 Xray："
    echo "  rc-service xray stop"
    echo
    echo "重启 Xray："
    echo "  rc-service xray restart"
    echo
    echo "查看状态："
    echo "  rc-service xray status"
    echo
    echo "查看端口监听："
    echo "  netstat -lntp | grep xray"
    echo
    echo "查看日志："
    echo "  tail -f ${XRAY_LOG_DIR}/error.log"
    echo
    echo "配置文件："
    echo "  ${XRAY_CONFIG_FILE}"
    echo
    echo "============================================================"
    echo " NAT 机器提醒"
    echo "============================================================"
    echo
    echo "请确认你的 NAT 面板中已经配置 TCP 端口转发："
    echo
    echo "  公网 IP:${PUBLIC_PORT}  ->  本机内网 IP:${LISTEN_PORT}"
    echo
    echo "Reality/VLESS TCP 模式不需要 UDP。"
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
    show_result
}

main "$@"
