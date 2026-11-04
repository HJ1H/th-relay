#!/usr/bin/env bash
# th-relay · bore 固定入口（替代 Cloudflare Quick Tunnel，无需任何账号）
#
# 用法：curl -fsSL https://raw.githubusercontent.com/HJ1H/th-relay/main/vps-bore.sh | bash
#
# 产出：
#   SSH   : ssh -p <SSH_PORT> root@bore.pub
#   Relay : http://bore.pub:<RELAY_PORT>/v1
# 两个端口都会自动挑没被占用的（bore.pub 上同端口先到先得）。
set -uo pipefail

BORE_BIN=/usr/local/bin/bore
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"
LOCAL_RELAY_PORT="${LOCAL_RELAY_PORT:-8080}"
SSH_PORT_PREF="${SSH_PORT_PREF:-41877}"
RELAY_PORT_PREF="${RELAY_PORT_PREF:-42777}"

echo "== bore 固定入口安装"
echo "   本机 ssh=$LOCAL_SSH_PORT  relay=$LOCAL_RELAY_PORT   首选端口 $SSH_PORT_PREF / $RELAY_PORT_PREF"

# ---------- 1. 装 bore ----------
echo "== [1/4] 下载 bore"
if ! "$BORE_BIN" --version >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64|amd64)  TARGET=x86_64-unknown-linux-musl ;;
    aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
    *) echo "!! 不支持的架构 $(uname -m)"; exit 1 ;;
  esac
  url_path="ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-${TARGET}.tar.gz"
  ok=0
  for base in "https://github.com" "https://ghfast.top/https://github.com" "https://ghproxy.net/https://github.com"; do
    if curl -fsSL -m 90 -o /tmp/bore.tgz "$base/$url_path"; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || { echo "!! bore 下载失败"; exit 1; }
  mkdir -p /tmp/bore_x && tar -xzf /tmp/bore.tgz -C /tmp/bore_x || { echo "!! 解压失败"; exit 1; }
  src=$(find /tmp/bore_x -type f -name bore | head -1)
  [ -n "$src" ] || { echo "!! 包里没有 bore"; exit 1; }
  systemctl stop bore-ssh bore-relay 2>/dev/null || true
  install -m 0755 "$src" "$BORE_BIN"
fi
"$BORE_BIN" --version 2>&1 | head -1

# ---------- 2. 挑端口 ----------
try_port() { # $1=local $2=remote
  timeout 8 "$BORE_BIN" local "$1" --to bore.pub --port "$2" >/tmp/bore-try.log 2>&1
  grep -q "listening at bore.pub:$2" /tmp/bore-try.log
}
pick_port() { # $1=local $2=标签 $3=首选端口
  local pref="$3" cand i
  for i in 0 1 2 3 4 5; do
    cand=$((pref + i * 1000))
    printf '   试端口 %s ... ' "$cand"
    if try_port "$1" "$cand"; then echo "可用"; echo "$cand"; return 0; fi
    echo "被占用或服务端拒绝"
  done
  return 1
}

echo "== [2/4] 申请固定端口（bore.pub 先到先得）"
SSH_PORT=$(pick_port "$LOCAL_SSH_PORT" ssh "$SSH_PORT_PREF") || { echo "!! SSH 端口全部失败"; exit 3; }
RELAY_PORT=$(pick_port "$LOCAL_RELAY_PORT" relay "$RELAY_PORT_PREF") || { echo "!! relay 端口全部失败"; exit 3; }
echo "   SSH -> bore.pub:$SSH_PORT    relay -> bore.pub:$RELAY_PORT"

# ---------- 3. systemd ----------
echo "== [3/4] 写服务"
write_unit() { # $1=name $2=local $3=remote $4=desc
  printf '%s\n' \
  '[Unit]' \
  "Description=bore tunnel ($4)" \
  'After=network-online.target' \
  'Wants=network-online.target' \
  '' \
  '[Service]' \
  'Type=simple' \
  "ExecStart=$BORE_BIN local $2 --to bore.pub --port $3" \
  'Restart=always' \
  'RestartSec=10' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' > "/etc/systemd/system/$1.service"
}
write_unit bore-ssh   "$LOCAL_SSH_PORT"   "$SSH_PORT"   ssh
write_unit bore-relay "$LOCAL_RELAY_PORT" "$RELAY_PORT" relay

systemctl daemon-reload
systemctl enable bore-ssh bore-relay >/dev/null 2>&1
systemctl restart bore-ssh bore-relay
sleep 8

# ---------- 4. 自检（从本机出发走公网回环，验的是真通） ----------
echo "== [4/4] 自检"
echo "   bore-ssh:   $(systemctl is-active bore-ssh 2>/dev/null)"
echo "   bore-relay: $(systemctl is-active bore-relay 2>/dev/null)"
echo "   --- 日志 ---"
journalctl -u bore-ssh   -n 6 --no-pager 2>/dev/null | sed 's/^/     /'
journalctl -u bore-relay -n 6 --no-pager 2>/dev/null | sed 's/^/     /'

echo "   --- 经 bore.pub 回环访问 /health ---"
code=$(curl -s -m 15 -o /tmp/h.txt -w "%{http_code}" "http://bore.pub:$RELAY_PORT/health" || echo 000)
echo "   http://bore.pub:$RELAY_PORT/health -> $code"
[ "$code" = 200 ] && echo "   ✅ 中转入口已固定可用" || echo "   ⚠️ 不是 200，可能是 Caddy 没起或端口没通，把上面日志发我"

echo
echo "== 完成"
echo "   SSH   : ssh -p $SSH_PORT root@bore.pub"
echo "   Relay : http://bore.pub:$RELAY_PORT/v1"
echo "   （bore 是明文 TCP 转发，key 走公网时没有 TLS；介意的话后续套自有域名）"
