#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/sepsiscare/backend}"
SERVICE_NAME="${SERVICE_NAME:-sepsiscare-api}"
HOST="${SEPSISCARE_HOST:-127.0.0.1}"
PORT="${SEPSISCARE_PORT:-8765}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

install -d -m 0755 "$APP_DIR"
for source_file in "$SOURCE_DIR"/*.py; do
  [[ -f "$source_file" ]] || continue
  install -m 0644 "$source_file" "$APP_DIR/$(basename "$source_file")"
done
install -m 0644 "$SOURCE_DIR/requirements.txt" "$APP_DIR/requirements.txt"
if [[ -d "$SOURCE_DIR/tools" ]]; then
  install -d -m 0755 "$APP_DIR/tools"
  for tool in "$SOURCE_DIR"/tools/*.py; do
    [[ -f "$tool" ]] || continue
    install -m 0644 "$tool" "$APP_DIR/tools/$(basename "$tool")"
  done
fi
if [[ -d "$SOURCE_DIR/runtime_data" ]]; then
  install -d -m 0755 "$APP_DIR/runtime_data"
  for data_file in history_patients.json history_details.json; do
    if [[ -f "$SOURCE_DIR/runtime_data/$data_file" ]]; then
      install -m 0644 "$SOURCE_DIR/runtime_data/$data_file" "$APP_DIR/runtime_data/$data_file"
    fi
  done
fi
if [[ -f "$SOURCE_DIR/.env" ]]; then
  install -m 0600 "$SOURCE_DIR/.env" "$APP_DIR/.env"
elif [[ ! -f "$APP_DIR/.env" && -f "$SOURCE_DIR/.env.example" ]]; then
  install -m 0600 "$SOURCE_DIR/.env.example" "$APP_DIR/.env"
fi

python3 -m py_compile "$APP_DIR"/*.py

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE
[Unit]
Description=SepsisCare local API
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=SEPSISCARE_DEVICE=cpu
ExecStart=/usr/bin/python3 ${APP_DIR}/server.py --host ${HOST} --port ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl
fi

if command -v nginx >/dev/null 2>&1; then
  cat > /etc/nginx/sites-available/sepsiscare <<NGINX
server {
    listen 80;
    server_name _;

    client_max_body_size 100m;

    location / {
        proxy_pass http://${HOST}:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
  ln -sf /etc/nginx/sites-available/sepsiscare /etc/nginx/sites-enabled/sepsiscare
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
fi

curl -fsS "http://${HOST}:${PORT}/health"
echo
echo "SepsisCare API is running on ${HOST}:${PORT}."
if command -v nginx >/dev/null 2>&1; then
  echo "Nginx reverse proxy is listening on port 80."
fi
