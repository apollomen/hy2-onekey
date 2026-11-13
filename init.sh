#!/bin/bash
set -euo pipefail

REPO="HyNetworks/hysteria"
BIN=/usr/local/bin/hysteria2
CONF_DIR=/etc/hy2
LINK_FILE=/root/hy2-link.txt
SNI="www.bing.com"
HOP_RANGE="20000-40000"
MODE="install"
[ "${1:-}" = "--rotate" ] && MODE="rotate"
[ "${1:-}" = "--uninstall" ] && MODE="uninstall"

log() { echo "[hy2] $*" >&2; }
die() { echo "[hy2] 错误：$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "必须以 root 运行"

uninstall() {
  printf '将停止并删除 Hysteria2（服务、NAT 转发规则、%s、%s），继续吗？[y/N] ' "$CONF_DIR" "$BIN" >&2
  read -r ans </dev/tty || ans=""
  case "$ans" in y|Y) ;; *) log "已取消"; exit 0 ;; esac
  systemctl disable --now hy2.service >/dev/null 2>&1 || true
  systemctl disable --now hy2-hop.service >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null || true
  rm -f /etc/systemd/system/hy2.service /etc/systemd/system/hy2-hop.service
  systemctl daemon-reload || true
  rm -rf "$CONF_DIR" "$BIN" "$LINK_FILE"
  log "已卸载"
  exit 0
}
[ "$MODE" = "uninstall" ] && uninstall

command -v systemctl >/dev/null || die "未找到 systemd"
command -v curl >/dev/null || die "未找到 curl"
command -v openssl >/dev/null || die "未找到 openssl"
command -v iptables >/dev/null || die "未找到 iptables"
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构：$(uname -m)" ;;
esac
ASSET="hysteria-linux-$ARCH"

log "正在查询 $REPO 最新版本 ..."
LATEST_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
TAG=$(echo "$LATEST_URL" | sed 's|.*/tag/||')
[ -n "$TAG" ] || die "无法获取最新版本号"
TAG_ENC=$(printf '%s' "$TAG" | sed 's|/|%2F|g')
BASE="https://github.com/$REPO/releases/download/$TAG_ENC"
log "最新版本：$TAG"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/hashes.txt" "$BASE/hashes.txt" || die "下载 hashes.txt 失败"
EXP_HASH=$(awk -v a="build/$ASSET" '$2==a {print $1}' "$TMP/hashes.txt")
[ -n "$EXP_HASH" ] || die "hashes.txt 中没有 $ASSET"
CUR_HASH=""
[ -x "$BIN" ] && CUR_HASH=$(sha256sum "$BIN" | awk '{print $1}')
if [ "$CUR_HASH" = "$EXP_HASH" ]; then
  log "已装二进制就是最新版（$TAG）且哈希一致，跳过下载"
else
  log "正在下载 $ASSET ..."
  curl -fsSL -o "$TMP/hysteria" "$BASE/$ASSET" || die "下载二进制失败"
  ACT_HASH=$(sha256sum "$TMP/hysteria" | awk '{print $1}')
  [ "$ACT_HASH" = "$EXP_HASH" ] || die "SHA256 不一致（应为 $EXP_HASH，实际 $ACT_HASH），中止"
  log "SHA256 校验通过：$ACT_HASH"
  if [ -x "$BIN" ]; then cp -a "$BIN" "$BIN.bak"; log "旧二进制已备份到 $BIN.bak"; fi
  install -m 755 "$TMP/hysteria" "$BIN"
fi
"$BIN" version 2>/dev/null | grep -i version | head -1 >&2 || true

mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/cert.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes \
    -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" -subj "/CN=$SNI" \
    -addext "subjectAltName=DNS:$SNI" 2>/dev/null
  log "已生成自签证书（SNI $SNI）"
else
  log "复用已有证书"
fi
if [ "$MODE" = "rotate" ]; then rm -f "$CONF_DIR/secrets.env"; log "正在轮换密码"; fi
if [ ! -f "$CONF_DIR/secrets.env" ]; then
  AUTH=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
  OBFS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
  printf 'AUTH=%s\nOBFS=%s\n' "$AUTH" "$OBFS" > "$CONF_DIR/secrets.env"
  chmod 600 "$CONF_DIR/secrets.env"
  log "已生成新密码"
else
  log "复用已有密码"
fi
. "$CONF_DIR/secrets.env"

cat > "$CONF_DIR/config.yaml" <<YAML
listen: :443
tls:
  cert: $CONF_DIR/cert.pem
  key: $CONF_DIR/key.pem
obfs:
  type: salamander
  salamander:
    password: $OBFS
auth:
  type: password
  password: $AUTH
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
YAML

cat > /etc/systemd/system/hy2.service <<UNIT
[Unit]
Description=Hysteria2 server (hy2-onekey)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN server -c $CONF_DIR/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/hy2-hop.service <<UNIT
[Unit]
Description=Hysteria2 port hopping redirect $HOP_RANGE -> 443
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
UNIT
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 443/udp >/dev/null; ufw allow 20000:40000/udp >/dev/null; log "已添加 ufw 放行规则"
fi
systemctl daemon-reload
systemctl enable --now hy2-hop.service >/dev/null 2>&1
systemctl enable hy2.service >/dev/null 2>&1
systemctl restart hy2.service

sleep 1
[ "$(systemctl is-active hy2.service)" = "active" ] || die "hy2.service 未运行（查看日志：journalctl -u hy2）"
[ "$(systemctl is-active hy2-hop.service)" = "active" ] || die "hy2-hop.service 未运行"
ss -ulnp 2>/dev/null | grep -q ':443 ' || die "UDP 443 未在监听"
iptables -t nat -C PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null || die "端口跳跃 NAT 规则缺失"
log "自检通过：服务运行中、UDP 443 监听中、跳跃规则已生效"

PUBIP=""
for svc in "https://api.ipify.org" "https://ip.sb" "https://ifconfig.me/ip"; do
  PUBIP=$(curl -4 -fsS --max-time 6 "$svc" 2>/dev/null | tr -d ' \n') || PUBIP=""
  [ -n "$PUBIP" ] && break
done
[ -n "$PUBIP" ] || die "无法获取公网 IP"
FP=$(openssl x509 -in "$CONF_DIR/cert.pem" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
NAME="Hysteria2-$(hostname)"
LINK="hysteria2://$AUTH@$PUBIP:443,$HOP_RANGE?obfs=salamander&obfs-password=$OBFS&pinSHA256=$FP&insecure=1&sni=$SNI#$NAME"
printf '%s\n' "$LINK" > "$LINK_FILE"; chmod 600 "$LINK_FILE"
log "完成（$TAG），链接已存到 $LINK_FILE"
echo "$LINK"
