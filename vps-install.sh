#!/usr/bin/env bash
# th-relay · VPS 一键安装（Caddy on :8080）
# 用法：curl -fsSL https://raw.githubusercontent.com/HJ1H/th-relay/main/vps-install.sh | bash
set -euo pipefail

CADDY_BIN=/usr/local/bin/caddy
CONF=/etc/caddy/Caddyfile

echo "[1/4] 下载 Caddy 静态二进制"
curl -fsSL -o "$CADDY_BIN" "https://caddyserver.com/api/download?os=linux&arch=amd64"
chmod +x "$CADDY_BIN"
"$CADDY_BIN" version

echo "[2/4] 写 Caddyfile"
mkdir -p /etc/caddy
cat > "$CONF" <<'CADDY'
:8080 {
	encode zstd gzip

	handle /v1/* {
		reverse_proxy https://tokenharbor.ai {
			header_up Host tokenharbor.ai
			transport http {
				tls_server_name tokenharbor.ai
				tls_timeout 15s
			}
			flush_interval -1
		}
	}

	handle /zen/* {
		reverse_proxy https://opencode.ai {
			header_up Host opencode.ai
			transport http {
				tls_server_name opencode.ai
				tls_timeout 15s
			}
			flush_interval -1
		}
	}

	handle /health {
		respond 200
	}

	handle {
		respond 404
	}
}
CADDY

echo "[3/4] 写 systemd 服务并启动"
cat > /etc/systemd/system/th-relay.service <<'UNIT'
[Unit]
Description=th-relay (Caddy on :8080)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now th-relay

echo "[4/4] 自检"
sleep 3
systemctl is-active th-relay
curl -s -o /dev/null -w "health=%{http_code}\n" --max-time 5 http://127.0.0.1:8080/health
curl -s -o /dev/null -w "tokenharbor=%{http_code}\n" --max-time 10 https://tokenharbor.ai/v1/models
echo "完成：health=200、tokenharbor=401 即正常（401 是没带 key）。"
