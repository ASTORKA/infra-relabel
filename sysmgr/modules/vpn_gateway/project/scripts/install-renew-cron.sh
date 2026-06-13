#!/usr/bin/env bash
set -euo pipefail

# Устанавливает cron-задачу для автообновления сертификатов 2 раза в сутки.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_CMD="cd ${ROOT_DIR} && ./scripts/renew-certs.sh >> ${ROOT_DIR}/edge/logs/cert-renew.log 2>&1"

mkdir -p "${ROOT_DIR}/edge/logs"
( { crontab -l 2>/dev/null || true; } | awk '!/scripts\/renew-certs\.sh/' ; echo "17 3,15 * * * ${CRON_CMD}" ) | crontab -

echo "[ok] Cron установлен: 17 3,15 * * *"