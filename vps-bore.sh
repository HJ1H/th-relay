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

# 所有人类可读输出一律走 stderr，stdout 只留给要被 $(...) 抓取的纯数据
say() { printf '%s\n' "$@" >&2; }

say "== bore 固定入口安装"
say "   本机 ssh=$LOCAL_SSH_PORT  relay=$LOCAL_RELAY_PORT   首选端口 $SSH_PORT_PREF / $RELAY_PORT_PREF"

# ---------- 1. 装 bore ----------
say "== [1/4] 下载 bore"
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

# ---------- 2. 挑端口 ----------
# stdout 只输出最终端口号，其余提示全部 >&2，避免污染返回值
pick_port() { # $1=本地端口 $2=首选远端端口
  local lport="$1" pref="$2" cand i got
  for i in 0 1 2 3 4 5; do
    cand=$((pref + i * 1000))
    printf '   试端口 %s ... ' "$cand" >&2
    timeout 8 "$BORE_BIN" local "$lport" --to bore.pub --port "$cand" >/tmp/bore-try.log 2>&1
    got=$(grep -oE "listening at bore\.pub:[0-9]+" /tmp/bore-try.log | head -1 | grep -oE '[0-9]+$')
    if [ -n "$got" ]; then
      say "可用"
      printf '%s' "$got"
      return 0
    fi
    say "失败"
    tail -2 /tmp/bore-try.log 2>/dev/null | sed 's/^/        /' >&2
  done
  return 1
}

say "== [2/4] 申请固定端口（bore.pub 先到先得）"
SSH_PORT=$(pick_port "$LOCAL_SSH_PORT" "$SSH_PORT_PREF") || { say "!! SSH 端口全部失败"; exit 3; }
RELAY_PORT=$(pick_port "$LOCAL_RELAY_PORT" "$RELAY_PORT_PREF") || { say "!! relay 端口全部失败"; exit 3; }

# 硬校验：必须是纯数字，否则宁可停下也别写进 systemd
for v in "$SSH_PORT" "$RELAY_PORT"; do
  case "$v" in
    ''|*[!0-9]*) say "!! 端口解析异常：“$v”，已中止（不会写 systemd）"; exit 4 ;;
  esac
done
say "   SSH -> bore.pub:$SSH_PORT    relay -> bore.pub:$RELAY_PORT"

# ---------- 3. systemd ----------
say "== [3/4] 写服务"
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
systemctl stop bore-ssh bore-relay 2>/dev/null || true
systemctl reset-failed bore-ssh bore-relay 2>/dev/null || true
systemctl enable bore-ssh bore-relay >/dev/null 2>&1
systemctl restart bore-ssh bore-relay
sleep 8

# ---------- 4. 自检 ----------
say "== [4/4] 自检"
say "   bore-ssh:   $(systemctl is-active bore-ssh 2>/dev/null)   bore-relay: $(systemctl is-active bore-relay 2>/dev/null)"
say "   --- 日志 ---"
journalctl -u bore-ssh   -n 5 --no-pager 2>/dev/null | sed 's/^/     /' >&2
journalctl -u bore-relay -n 5 --no-pager 2>/dev/null | sed 's/^/     /' >&2

say "   --- 经 bore.pub 回环访问 /health（验真通，不是看进程在不在）---"
code=$(curl -s -m 15 -o /tmp/h.txt -w "%{http_code}" "http://bore.pub:$RELAY_PORT/health" 2>/dev/null || echo 000)
say "   http://bore.pub:$RELAY_PORT/health -> $code"
if [ "$code" = 200 ]; then
  say "   ✅ 中转入口已固定可用"
else
  say "   ⚠️ 非 200。Caddy 是否在听 8080：$(ss -lnt 2>/dev/null | grep -c ":$LOCAL_RELAY_PORT ") 条"
fi

say ""
say "== 完成"
say "   SSH   : ssh -p $SSH_PORT root@bore.pub"
say "   Relay : http://bore.pub:$RELAY_PORT/v1"
say "   （bore 是明文 TCP 转发，key 走公网时没有 TLS；介意的话后续套自有域名）"
