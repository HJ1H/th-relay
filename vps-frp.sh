#!/usr/bin/env bash
# th-relay · frp 客户端（固定入口，替代 Cloudflare Quick Tunnel）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/HJ1H/th-relay/main/vps-frp.sh | bash
#
# 可选覆盖（默认已内置面板给的凭据）：
#   FRP_TOKEN=xxx FRP_USER=yyy SSH_REMOTE_PORT=41877 bash vps-frp.sh
#
# 做的事：下载官方 frpc → 自动试几个版本直到登录成功 → 写 systemd 服务 → 拉起 → 自检
set -uo pipefail

SERVER_ADDR="${FRP_SERVER:-103.24.219.85}"
SERVER_PORT="${FRP_PORT:-7000}"
FRP_TOKEN="${FRP_TOKEN:-212a868cbbbf7c01049fea68b13bf}"
FRP_USER="${FRP_USER:-a0944fe9689ab}"
SSH_REMOTE_PORT="${SSH_REMOTE_PORT:-41877}"
RELAY_REMOTE_PORT="${RELAY_REMOTE_PORT:-6277}"
RELAY_LOCAL_PORT="${RELAY_LOCAL_PORT:-8080}"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "!! 不支持的架构: $(uname -m)"; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dl() { # $1=version  $2=output
  local ver="$1" out="$2" base
  for base in \
    "https://github.com/fatedier/frp/releases/download" \
    "https://ghfast.top/https://github.com/fatedier/frp/releases/download" \
    "https://ghproxy.net/https://github.com/fatedier/frp/releases/download" ; do
    if curl -fsSL --connect-timeout 10 -m 120 -o "$out" "$base/v${ver}/frp_${ver}_linux_${ARCH}.tar.gz"; then
      return 0
    fi
  done
  return 1
}

write_toml() { # frp >= 0.52
  cat > "$1" <<EOF
serverAddr = "$SERVER_ADDR"
serverPort = $SERVER_PORT
user = "$FRP_USER"

auth.method = "token"
auth.token = "$FRP_TOKEN"

transport.tls.enable = true

[[proxies]]
name = "ech0-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $SSH_REMOTE_PORT

[[proxies]]
name = "ech0-relay"
type = "tcp"
localIP = "127.0.0.1"
localPort = $RELAY_LOCAL_PORT
remotePort = $RELAY_REMOTE_PORT
EOF
}

write_ini() { # frp < 0.52
  cat > "$1" <<EOF
[common]
server_addr = $SERVER_ADDR
server_port = $SERVER_PORT
token = $FRP_TOKEN
user = $FRP_USER
tls_enable = true

[ech0-ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = $SSH_REMOTE_PORT

[ech0-relay]
type = tcp
local_ip = 127.0.0.1
local_port = $RELAY_LOCAL_PORT
remote_port = $RELAY_REMOTE_PORT
EOF
}

echo "== 目标服务端 $SERVER_ADDR:$SERVER_PORT   本机架构 $ARCH"
echo "== 端口规划 ssh->$SSH_REMOTE_PORT  relay($RELAY_LOCAL_PORT)->$RELAY_REMOTE_PORT"
echo "== 凭据 token=${FRP_TOKEN:0:4}****(${#FRP_TOKEN}位)  user=${FRP_USER:-<空>}"
if [ "${#FRP_TOKEN}" -ne 16 ]; then
  echo "!! 该 frps 要求 token 必须是 16 位字母或数字，当前 ${#FRP_TOKEN} 位 —— 大概率会被 token_format 拒掉。"
  echo "!! 请到面板复制真实 token，再跑：FRP_TOKEN=xxxxxxxxxxxxxxxx FRP_USER=yyyy bash /tmp/frp.sh"
fi

echo "== [预检] 本机 sshd（frp 只是把本机 22 转出去，本机没 sshd 就白转）"
if ! ss -lnt 2>/dev/null | grep -qE '(^|[.:])22 '; then
  echo "   22 端口没在听，尝试安装 openssh-server"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq openssh-server >/dev/null 2>&1
    mkdir -p /run/sshd
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
    sleep 2
  fi
fi
if ss -lnt 2>/dev/null | grep -qE '(^|[.:])22 '; then
  echo "   sshd 在听 :22"
  # 面板给的是 root+密码登录；debian 默认 PermitRootLogin 是 prohibit-password，会直接拒密码
  if grep -qiE '^\s*PermitRootLogin\s+prohibit-password' /etc/ssh/sshd_config 2>/dev/null; then
    echo "   !! sshd 禁止 root 密码登录，改为 yes（面板本来就是密码登录模式）"
    sed -i 's/^\s*PermitRootLogin\s\+prohibit-password/PermitRootLogin yes/I' /etc/ssh/sshd_config
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
else
  echo "   !! 22 仍然没在听 —— SSH 那条代理会 start error，但 relay 代理不受影响"
fi

LOG="$work/frpc-test.log"
OK_VER=""; OK_BIN=""; OK_CFG=""

for spec in "0.61.1 toml" "0.58.1 toml" "0.52.3 toml" "0.51.3 ini" "0.44.0 ini"; do
  set -- $spec; ver="$1"; fmt="$2"
  printf '== [%s] 下载... ' "$ver"
  if ! dl "$ver" "$work/frp.tgz"; then echo "失败（网络/镜像都不通），跳过"; continue; fi
  rm -rf "$work/x"; mkdir -p "$work/x"
  tar -xzf "$work/frp.tgz" -C "$work/x" 2>/dev/null || { echo "解压失败，跳过"; continue; }
  bin=$(find "$work/x" -type f -name frpc | head -1)
  [ -n "$bin" ] || { echo "包里没有 frpc，跳过"; continue; }
  chmod +x "$bin"

  if [ "$fmt" = toml ]; then cfg="$work/frpc.toml"; write_toml "$cfg"; else cfg="$work/frpc.ini"; write_ini "$cfg"; fi

  printf '登录测试... '
  timeout 18 "$bin" -c "$cfg" >"$LOG" 2>&1
  if grep -q "login to server success" "$LOG"; then
    echo "成功"
    OK_VER="$ver"; OK_BIN="$bin"; OK_CFG="$cfg"
    break
  fi
  echo "失败"
  if grep -qiE "authentication failed|authorization failed|token .*doesn't match|invalid user|no permission|token_format|令牌格式|重新下载完整配置" "$LOG"; then
    echo "!! 凭据被服务端拒绝，先停下（不是版本问题）。服务端原话："
    grep -iE "authentication|authorization|token|user|permission" "$LOG" | head -5
    echo "!! 请回面板重新复制 token / user，再用 FRP_TOKEN=... FRP_USER=... 重跑。"
    exit 2
  fi
  grep -iE "error|fail|refused|timed out|timeout|tls" "$LOG" | head -6
done

if [ -z "$OK_VER" ]; then
  echo "!! 所有版本都登录失败。把上面每轮的报错发我。"
  exit 3
fi

echo "== [安装] frpc $OK_VER"
mkdir -p /etc/frp
install -m 0755 "$OK_BIN" /usr/local/bin/frpc
case "$OK_CFG" in
  *.toml) install -m 0600 "$OK_CFG" /etc/frp/frpc.toml; CFG_OUT=/etc/frp/frpc.toml ;;
  *.ini)  install -m 0600 "$OK_CFG" /etc/frp/frpc.ini;  CFG_OUT=/etc/frp/frpc.ini  ;;
esac

# 自检：本机 SSH / relay 是否有在听
echo "== [自检] 本机监听"
ss -lnt 2>/dev/null | grep -E ':(22|'"$RELAY_LOCAL_PORT"')\b' || echo "   （:22 或 :$RELAY_LOCAL_PORT 没在听，对应那条代理会 start error）"

printf '%s\n' \
'[Unit]' \
'Description=frp client (ech0 tunnel)' \
'After=network-online.target' \
'Wants=network-online.target' \
'' \
'[Service]' \
'Type=simple' \
"ExecStart=/usr/local/bin/frpc -c $CFG_OUT" \
'Restart=always' \
'RestartSec=5' \
'LimitNOFILE=1048576' \
'' \
'[Install]' \
'WantedBy=multi-user.target' > /etc/systemd/system/frpc.service

echo "== [启动] systemd"
systemctl daemon-reload
systemctl enable frpc >/dev/null 2>&1
systemctl restart frpc
sleep 6

echo "== [状态] $(systemctl is-active frpc 2>/dev/null)"
journalctl -u frpc -n 25 --no-pager 2>/dev/null | sed 's/^/   /'
echo "== [监听]"
ss -lntp 2>/dev/null | grep -E 'frpc|:(22|'"$RELAY_LOCAL_PORT"')' || true

echo
echo "== 完成。隧道通了的话，服务端侧入口应为："
echo "   SSH   : $SERVER_ADDR:$SSH_REMOTE_PORT"
echo "   Relay : http://$SERVER_ADDR:$RELAY_REMOTE_PORT/v1"
echo "   （具体端口以日志里 'start proxy success' 那条为准）"
