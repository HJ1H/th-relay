#!/usr/bin/env bash
# th-relay · ngrok 固定 HTTPS 入口（边缘终结 TLS，免费档自带 1 个固定 dev domain）
#
# 用法：
#   NGROK_TOKEN=<你的 authtoken> bash vps-ngrok.sh
#   可选：NGROK_DOMAIN=xxx.ngrok-free.app（不给就自动用账号分配的 dev domain）
#
# 免费档限制（2026-11 核实）：1 GB/月流量、20k 请求/月、3 个并发 endpoint；
# 无 endpoint 超时；HTML 浏览器流量会过警告页，**API/程序化请求不受影响**。
set -uo pipefail

VER="v1-2026-11-04"
NGROK_BIN=/usr/local/bin/ngrok
LOCAL_PORT="${LOCAL_PORT:-8080}"
TOKEN="${NGROK_TOKEN:-}"
DOMAIN="${NGROK_DOMAIN:-}"

say() { printf '%s\n' "$@" >&2; }

say "== ngrok 固定 HTTPS 入口  [$VER]"
[ -n "$TOKEN" ] || { say "!! 缺 NGROK_TOKEN。用法：NGROK_TOKEN=xxxx bash vps-ngrok.sh"; exit 1; }

# ---------- 1. 装 ngrok ----------
say "== [1/4] 准备 ngrok"
if ! "$NGROK_BIN" version >/dev/null 2>&1; then
  ok=0
  for url in \
    "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz" \
    "https://ghfast.top/https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz" ; do
    if curl -fsSL -m 120 -o /tmp/ngrok.tgz "$url"; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || { say "!! ngrok 下载失败"; exit 1; }
  tar -xzf /tmp/ngrok.tgz -C /tmp || { say "!! 解压失败"; exit 1; }
  systemctl stop ngrok 2>/dev/null || true
  install -m 0755 /tmp/ngrok "$NGROK_BIN"
  rm -f /tmp/ngrok
fi
say "   $("$NGROK_BIN" version 2>&1 | head -1)"

# ---------- 2. 写 authtoken ----------
say "== [2/4] 配置 authtoken"
"$NGROK_BIN" config add-authtoken "$TOKEN" >/dev/null 2>&1 || { say "!! authtoken 写入失败"; exit 2; }
say "   已写入 /root/.config/ngrok/ngrok.yml"

# ---------- 3. systemd ----------
say "== [3/4] 写服务"
if [ -n "$DOMAIN" ]; then
  EXEC="$NGROK_BIN http $LOCAL_PORT --domain=$DOMAIN --log=stdout --log-format=logfmt"
else
  EXEC="$NGROK_BIN http $LOCAL_PORT --log=stdout --log-format=logfmt"
fi
printf '%s\n' \
'[Unit]' \
'Description=ngrok tunnel (relay https)' \
'After=network-online.target' \
'Wants=network-online.target' \
'' \
'[Service]' \
'Type=simple' \
"ExecStart=$EXEC" \
'Restart=always' \
'RestartSec=10' \
'' \
'[Install]' \
'WantedBy=multi-user.target' > /etc/systemd/system/ngrok.service

systemctl daemon-reload
systemctl reset-failed ngrok >/dev/null 2>&1
systemctl enable ngrok >/dev/null 2>&1
systemctl restart ngrok
say "   $(grep '^ExecStart' /etc/systemd/system/ngrok.service)"

# ---------- 4. 自检 ----------
say "== [4/4] 自检（等 ngrok 建链，最多 30s）"
PUBLIC=""
for i in $(seq 1 30); do
  sleep 1
  PUBLIC=$(curl -s -m 3 http://127.0.0.1:4040/api/tunnels 2>/dev/null \
           | grep -oE '"public_url":"https://[^"]+' | head -1 | cut -d'"' -f4)
  [ -n "$PUBLIC" ] && break
done

if [ -z "$PUBLIC" ]; then
  say "   ⚠️ 拿不到 public_url，ngrok 日志："
  journalctl -u ngrok -n 12 --no-pager 2>/dev/null | sed 's/^/     /' >&2
  say "   常见原因：authtoken 无效 / 免费额度已满（3 个 endpoint）/ 域名被占用"
  exit 3
fi

say "   public_url: $PUBLIC"
code=$(curl -s -m 15 -o /dev/null -w "%{http_code}" "$PUBLIC/health" 2>/dev/null)
[ -n "${code:-}" ] || code=000
say "   $PUBLIC/health -> $code"
if [ "$code" = 200 ]; then
  say "   ✅ 固定 HTTPS 入口可用（边缘 TLS，bore 上的明文问题在这条线上不存在）"
else
  say "   ⚠️ 非 200，检查 Caddy 是否在听 $LOCAL_PORT"
fi

say ""
say "== 完成"
say "   Relay（HTTPS，固定）: $PUBLIC/v1"
say "   SSH（固定，仅密钥）  : ssh -p 41877 -i ~/.ssh/th_vps root@bore.pub"
