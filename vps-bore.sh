#!/usr/bin/env bash
# th-relay · bore 固定入口（替代 Cloudflare Quick Tunnel，无需任何账号）
#
# 用法：curl -fsSL -H "Accept: application/vnd.github.raw" \
#        "https://api.github.com/repos/HJ1H/th-relay/contents/vps-bore.sh?ref=main" -o /tmp/b.sh && bash /tmp/b.sh
#
# 产出：
#   SSH   : ssh -p <SSH_PORT> root@bore.pub
#   Relay : http://bore.pub:<RELAY_PORT>/v1
#
# 设计要点：不再「先试端口、再起服务」（两者之间会撞 port already in use），
# 而是直接拿端口去起 systemd 服务，起不来就换下一个端口重来——一次判断到底。
set -uo pipefail

VER="v4-2026-11-04"
BORE_BIN=/usr/local/bin/bore
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"
LOCAL_RELAY_PORT="${LOCAL_RELAY_PORT:-8080}"
SSH_PORT_PREF="${SSH_PORT_PREF:-41877}"
RELAY_PORT_PREF="${RELAY_PORT_PREF:-42777}"

# 人类可读输出一律走 stderr，stdout 只留给要被 $(...) 抓取的纯数据
say() { printf '%s\n' "$@" >&2; }

say "== bore 固定入口安装  [$VER]"
say "   本机 ssh=$LOCAL_SSH_PORT  relay=$LOCAL_RELAY_PORT   首选端口 $SSH_PORT_PREF / $RELAY_PORT_PREF"

# ---------- 1. 装 bore ----------
say "== [1/4] 准备 bore"
if ! "$BORE_BIN" --version >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64|amd64)  TARGET=x86_64-unknown-linux-musl ;;
    aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
    *) say "!! 不支持的架构 $(uname -m)"; exit 1 ;;
  esac
  url_path="ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-${TARGET}.tar.gz"
  ok=0
  for base in "https://github.com" "https://ghfast.top/https://github.com" "https://ghproxy.net/https://github.com"; do
    if curl -fsSL -m 90 -o /tmp/bore.tgz "$base/$url_path"; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || { say "!! bore 下载失败"; exit 1; }
  rm -rf /tmp/bore_x && mkdir -p /tmp/bore_x
  tar -xzf /tmp/bore.tgz -C /tmp/bore_x || { say "!! 解压失败"; exit 1; }
  src=$(find /tmp/bore_x -type f -name bore | head -1)
  [ -n "$src" ] || { say "!! 包里没有 bore"; exit 1; }
  systemctl stop bore-ssh bore-relay 2>/dev/null || true
  install -m 0755 "$src" "$BORE_BIN"
fi
say "   $("$BORE_BIN" --version 2>&1 | head -1)"

# 自动确认「申请固定远端端口」这个参数到底叫什么
PORT_FLAG=""
help_local=$("$BORE_BIN" local --help 2>&1)
if printf '%s' "$help_local" | grep -q -- '--port'; then
  PORT_FLAG="--port"
elif printf '%s' "$help_local" | grep -qE '(^|[[:space:]])-p([,[:space:]]|$)'; then
  PORT_FLAG="-p"
else
  say "!! bore local 里找不到申请固定端口的参数，帮助原文如下："
  printf '%s\n' "$help_local" | sed 's/^/     /' >&2
  exit 5
fi
say "   固定端口参数：$PORT_FLAG"

# ---------- 2. systemd 单元 + 起服务并验证 ----------
write_unit() { # $1=name $2=local $3=remote $4=desc
  printf '%s\n' \
  '[Unit]' \
  "Description=bore tunnel ($4)" \
  'After=network-online.target' \
  'Wants=network-online.target' \
  '' \
  '[Service]' \
  'Type=simple' \
  "ExecStart=$BORE_BIN local $2 --to bore.pub $PORT_FLAG $3" \
  'Restart=always' \
  'RestartSec=10' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' > "/etc/systemd/system/$1.service"
  systemctl daemon-reload
}

start_tunnel() { # $1=unit $2=local $3=pref  → stdout 输出最终端口号
  local unit="$1" lport="$2" pref="$3" cand i t
  for i in 0 1 2 3 4 5; do
    cand=$((pref + i * 1000))
    printf '   %s 用端口 %s ... ' "$unit" "$cand" >&2
    write_unit "$unit" "$lport" "$cand" "$unit"
    systemctl reset-failed "$unit" >/dev/null 2>&1
    since=$(date -d '-25 seconds' '+%Y-%m-%d %H:%M:%S')
    systemctl restart "$unit"
    for t in $(seq 1 12); do
      sleep 1
      if journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null | grep -q "listening at bore.pub:$cand"; then
        say "成功"
        printf '%s' "$cand"
        return 0
      fi
      [ "$(systemctl is-active "$unit" 2>/dev/null)" = active ] || break
    done
    say "失败"
    journalctl -u "$unit" -n 2 --no-pager 2>/dev/null | sed 's/^/       /' >&2
    systemctl stop "$unit" 2>/dev/null || true
  done
  return 1
}

say "== [2/4] 建立隧道（bore.pub 上同端口先到先得）"
# 通过 SSH 在远端跑本脚本时，重启 bore-ssh 会把自己踢下线。
# SKIP_SSH=1 表示沿用已在跑的 SSH 隧道，只重建 relay。
SKIP_SSH="${SKIP_SSH:-0}"
if [ "$SKIP_SSH" = 1 ] && systemctl is-active --quiet bore-ssh 2>/dev/null; then
  SSH_PORT=$(journalctl -u bore-ssh -n 200 --no-pager 2>/dev/null \
             | grep -oE 'listening at bore\.pub:[0-9]+' | tail -1 | grep -oE '[0-9]+$')
  say "   bore-ssh 已在跑，沿用端口 ${SSH_PORT:-?}（SKIP_SSH=1）"
  [ -n "${SSH_PORT:-}" ] || SSH_PORT="$SSH_PORT_PREF"
else
  SSH_PORT=$(start_tunnel bore-ssh "$LOCAL_SSH_PORT" "$SSH_PORT_PREF") || { say "!! SSH 隧道建立失败"; exit 3; }
fi
RELAY_PORT=$(start_tunnel bore-relay "$LOCAL_RELAY_PORT" "$RELAY_PORT_PREF") || { say "!! relay 隧道建立失败"; exit 3; }

for v in "$SSH_PORT" "$RELAY_PORT"; do
  case "$v" in ''|*[!0-9]*) say "!! 端口解析异常：“$v”，已中止"; exit 4 ;; esac
done
say "   SSH -> bore.pub:$SSH_PORT    relay -> bore.pub:$RELAY_PORT"

say "== [3/4] 开机自启"
systemctl enable bore-ssh bore-relay >/dev/null 2>&1
say "   $(systemctl is-enabled bore-ssh 2>/dev/null) / $(systemctl is-enabled bore-relay 2>/dev/null)"

# ---------- 4. 自检 ----------
say "== [4/4] 自检（走公网回环，不是只看进程）"
say "   bore-ssh: $(systemctl is-active bore-ssh)   bore-relay: $(systemctl is-active bore-relay)"
code=$(curl -s -m 15 -o /tmp/h.txt -w "%{http_code}" "http://bore.pub:$RELAY_PORT/health" 2>/dev/null)
[ -n "${code:-}" ] || code=000
say "   http://bore.pub:$RELAY_PORT/health -> $code"
if [ "$code" = 200 ]; then say "   ✅ 中转入口已固定可用"; else say "   ⚠️ 非 200 —— Caddy 在听 8080 的连接数：$(ss -lnt 2>/dev/null | grep -c ":$LOCAL_RELAY_PORT ")"; fi

say ""
say "== 完成"
say "   SSH   : ssh -p $SSH_PORT root@bore.pub"
say "   Relay : http://bore.pub:$RELAY_PORT/v1"
say "   注意：bore 是明文 TCP 转发，公网上没有 TLS，API key 会以明文经过 bore.pub。"
