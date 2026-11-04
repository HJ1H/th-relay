#!/usr/bin/env bash
# th-relay · Cloudflare 命名隧道（固定 HTTPS + 不限流量，替代 Quick Tunnel / bore / ngrok）
#
# 前置（一次性，在 Cloudflare 面板做）：
#   1. 域名 NS 已指向 Cloudflare（zone 状态 Active）
#   2. Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared
#      复制那条 `cloudflared service install <TOKEN>` 里的 TOKEN
#   3. 在同一条隧道的 Public Hostname 里加：
#        Subdomain: relay      Domain: 你的域名      Service: HTTP → localhost:8080
#
# 用法：
#   CF_TUNNEL_TOKEN=<token> bash vps-cf-named.sh
#   CF_TUNNEL_TOKEN=<token> PUBLIC_HOST=relay.example.eu.org bash vps-cf-named.sh
set -uo pipefail

VER="v1-2026-11-04"
TOKEN="${CF_TUNNEL_TOKEN:-}"
PUBLIC_HOST="${PUBLIC_HOST:-}"

say() { printf '%s\n' "$@" >&2; }

say "== Cloudflare 命名隧道  [$VER]"
[ -n "$TOKEN" ] || { say "!! 缺 CF_TUNNEL_TOKEN"; say "   用法：CF_TUNNEL_TOKEN=xxx bash vps-cf-named.sh"; exit 1; }

# ---------- 1. cloudflared ----------
say "== [1/4] 检查 cloudflared"
if ! command -v cloudflared >/dev/null 2>&1; then
  say "   未安装，下载中"
  curl -fsSL -m 120 -o /tmp/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    || { say "!! cloudflared 下载失败"; exit 1; }
  install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
fi
say "   $(cloudflared --version 2>&1 | head -1)"

# ---------- 2. 停掉 Quick Tunnel，避免抢 8080 的上游 ----------
say "== [2/4] 停用旧的 Quick Tunnel"
systemctl disable --now cf-tunnel 2>/dev/null && say "   已停 cf-tunnel（Quick Tunnel，URL 会变）" || say "   cf-tunnel 本来就没在跑"

# ---------- 3. 安装命名隧道服务 ----------
say "== [3/4] 安装隧道服务"
# cloudflared service install 会把 token 写进 /etc/cloudflared/config.yml（0600）
cloudflared service uninstall >/dev/null 2>&1 || true
cloudflared service install "$TOKEN" >/tmp/cf-install.log 2>&1 || {
  say "!! 安装失败："; tail -8 /tmp/cf-install.log | sed 's/^/     /' >&2; exit 2; }
systemctl enable cloudflared >/dev/null 2>&1
systemctl restart cloudflared
sleep 8
say "   服务状态：$(systemctl is-active cloudflared 2>/dev/null)"

# ---------- 4. 自检 ----------
say "== [4/4] 自检"
journalctl -u cloudflared -n 12 --no-pager 2>/dev/null | sed 's/^/     /' >&2

if [ -z "$PUBLIC_HOST" ]; then
  say ""
  say "!! 没给 PUBLIC_HOST，跳过外部自检。"
  say "   请在 CF 面板确认 Public Hostname 已指向 http://localhost:8080，然后手动验证："
  say "     curl -s -o /dev/null -w '%{http_code}\\n' https://<你的域名>/health"
  exit 0
fi

say "   目标主机：$PUBLIC_HOST"
for i in 1 2 3 4 5 6 7 8 9 10; do
  code=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "https://$PUBLIC_HOST/health" 2>/dev/null)
  [ -n "${code:-}" ] || code=000
  say "   第 ${i} 次：https://$PUBLIC_HOST/health -> $code"
  [ "$code" = 200 ] && break
  sleep 6
done

if [ "$code" = 200 ]; then
  say ""
  say "   ✅ 固定 HTTPS 入口已就绪"
  say "   Relay : https://$PUBLIC_HOST/v1"
  say "   流量   : Cloudflare 免费档不计量；TLS 在边缘终结，bore/ngrok 那套明文顾虑不复存在"
else
  say ""
  say "   ⚠️ 还不是 200。常见原因（按概率排序）："
  say "     1) CF 面板里没加 Public Hostname，或 Service 没指向 http://localhost:8080"
  say "     2) DNS 记录没生成（Tunnels 页面会自动建 CNAME，稍等一两分钟）"
  say "     3) 本机 Caddy 没在听 8080：$(ss -lnt 2>/dev/null | grep -c ':8080 ')"
fi
