#!/usr/bin/env bash
set -euo pipefail

# Автообновление Let's Encrypt и безопасный reload edge-nginx.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_FILE="${ROOT_DIR}/config/gateway.yml"
LE_DIR="${ROOT_DIR}/edge/letsencrypt"
CERTS_DIR="${ROOT_DIR}/edge/certs"
ACME_WEBROOT_DIR="${ROOT_DIR}/edge/acme-challenge"

# Используем venv python если есть (PyYAML может быть только там), иначе системный python3
if [[ -x "${ROOT_DIR}/.venv/bin/python" ]]; then
  PYTHON="${ROOT_DIR}/.venv/bin/python"
else
  PYTHON="python3"
fi

mkdir -p "${LE_DIR}" "${CERTS_DIR}" "${ACME_WEBROOT_DIR}"

readarray -t CFG_VALUES < <(CFG_FILE="${CFG_FILE}" "${PYTHON}" - <<'PY'
import os
import yaml
from pathlib import Path
cfg = yaml.safe_load(Path(os.environ['CFG_FILE']).read_text(encoding='utf-8')) or {}
quick = cfg.get('quick_setup', {}) or {}
project = cfg.get('project', {}) or {}
edge = cfg.get('edge', {}) or {}
primary = quick.get('public_domain') or project.get('public_domain') or ''
print(primary)
print(quick.get('acme_email') or '')
print(str(quick.get('acme_enabled', True)).lower())
print(str(edge.get('http_port', 80)))
print(str(edge.get('https_port', 443)))
add_domains = set()
for p in (cfg.get('landing', {}) or {}).get('pages', []):
    for d in p.get('domains', []):
        if d.strip() and d.strip() != primary:
            add_domains.add(d.strip())
print(" ".join(list(add_domains)))
PY
)

EDGE_DOMAIN="${CFG_VALUES[0]:-}"
ACME_EMAIL="${CFG_VALUES[1]:-}"
ACME_ENABLED="${CFG_VALUES[2]:-true}"
EDGE_HTTP_PORT="${CFG_VALUES[3]:-80}"
EDGE_HTTPS_PORT="${CFG_VALUES[4]:-443}"
EDGE_ADDITIONAL_DOMAINS="${CFG_VALUES[5]:-}"

if [[ -z "${EDGE_DOMAIN}" ]]; then
  echo "[error] Проверьте quick_setup.public_domain в config/gateway.yml" >&2
  exit 1
fi

if [[ "${ACME_ENABLED}" != "true" || "${EDGE_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[ok] ACME выключен или используется IP, renew не требуется"
  exit 0
fi

if [[ -z "${ACME_EMAIL}" || "${ACME_EMAIL}" == "admin@example.com" ]]; then
  echo "[error] Проверьте quick_setup.acme_email в config/gateway.yml" >&2
  exit 1
fi

cd "${ROOT_DIR}"

# Генерируем edge/.env.edge из конфига (нужен docker-compose.edge.yml для парсинга)
mkdir -p "${ROOT_DIR}/edge"
cat > "${ROOT_DIR}/edge/.env.edge" << ENVEOF
EDGE_DOMAIN=${EDGE_DOMAIN}
EDGE_ADDITIONAL_DOMAINS=${EDGE_ADDITIONAL_DOMAINS}
EDGE_HTTP_PORT=${EDGE_HTTP_PORT}
EDGE_HTTPS_PORT=${EDGE_HTTPS_PORT}
ENVEOF

# Поддерживаем и docker compose (v2+), и legacy docker-compose
if docker compose version &>/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  echo "[error] Не найден ни 'docker compose', ни 'docker-compose'." >&2; exit 1
fi


if command -v certbot >/dev/null 2>&1; then
  certbot renew --webroot -w "${ACME_WEBROOT_DIR}" --quiet
  if [[ -f "/etc/letsencrypt/live/${EDGE_DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${EDGE_DOMAIN}/privkey.pem" ]]; then
    cp -f "/etc/letsencrypt/live/${EDGE_DOMAIN}/fullchain.pem" "${CERTS_DIR}/fullchain.pem"
    cp -f "/etc/letsencrypt/live/${EDGE_DOMAIN}/privkey.pem"   "${CERTS_DIR}/privkey.pem"
  fi
else
  docker run --rm \
    -v "${ACME_WEBROOT_DIR}:/var/www/acme-challenge" \
    -v "${LE_DIR}:/etc/letsencrypt" \
    certbot/certbot:latest renew --webroot -w /var/www/acme-challenge --quiet
  if [[ -f "${LE_DIR}/live/${EDGE_DOMAIN}/fullchain.pem" && -f "${LE_DIR}/live/${EDGE_DOMAIN}/privkey.pem" ]]; then
    cp -f "${LE_DIR}/live/${EDGE_DOMAIN}/fullchain.pem" "${CERTS_DIR}/fullchain.pem"
    cp -f "${LE_DIR}/live/${EDGE_DOMAIN}/privkey.pem"   "${CERTS_DIR}/privkey.pem"
  fi
fi

# Синхронизация с персистентным хранилищем бэкапа
PERSIST_CERTS_DIR="/etc/sysmgr-bedolaga/certs/${EDGE_DOMAIN}"
if [[ -f "${CERTS_DIR}/fullchain.pem" && -f "${CERTS_DIR}/privkey.pem" ]]; then
  mkdir -p "${PERSIST_CERTS_DIR}" 2>/dev/null && \
    cp -f "${CERTS_DIR}/fullchain.pem" "${PERSIST_CERTS_DIR}/fullchain.pem" && \
    cp -f "${CERTS_DIR}/privkey.pem"   "${PERSIST_CERTS_DIR}/privkey.pem"   && \
    chmod 600 "${PERSIST_CERTS_DIR}/privkey.pem" && \
    echo "[ok] Сертификат продублирован в бэкап ${PERSIST_CERTS_DIR}" || \
    echo "[warn] Не удалось скопировать сертификат в бэкап ${PERSIST_CERTS_DIR}"
fi

# Релоад встроенного nginx (только если запущен)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vpn-edge-nginx"; then
  EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml exec -T edge-nginx nginx -t || true
  EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml exec -T edge-nginx nginx -s reload || true
  echo "[ok] Встроенный edge-nginx успешно перезагружен"
fi

# Релоад внешнего инжектированного nginx, если он настроен
PERSIST_INJ="/etc/sysmgr-bedolaga/nginx_injection.env"
if [[ -f "$PERSIST_INJ" ]]; then
  echo "[info] Обнаружено авто-внедрение внешнего Nginx. Выполняю перезапуск..."
  saved_type=$(grep '^NGINX_TYPE=' "$PERSIST_INJ" | cut -d= -f2-)
  saved_file=$(grep '^CONF_FILE=' "$PERSIST_INJ" | cut -d= -f2-)
  saved_domain=$(grep '^DOMAIN=' "$PERSIST_INJ" | cut -d= -f2-)
  
  if [[ "$saved_type" == "host:nginx" ]]; then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null && echo "[ok] Хостовый nginx успешно перезагружен" || echo "[warn] Не удалось перезагрузить хостовый nginx"
    else
      echo "[error] Ошибка конфигурации хостового nginx!"
    fi
  elif [[ "$saved_type" == docker:* ]]; then
    cname=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx | grep -v vpn-edge-nginx | head -1)
    if [[ -n "$cname" ]]; then
      if [[ "$saved_type" == "docker:monolith" ]]; then
        echo "[info] Обновляю сертификаты для монолитного Nginx..."
        mkdir -p "/etc/letsencrypt/live/${saved_domain}"
        cp -f "${CERTS_DIR}/fullchain.pem" "/etc/letsencrypt/live/${saved_domain}/fullchain.pem"
        cp -f "${CERTS_DIR}/privkey.pem"   "/etc/letsencrypt/live/${saved_domain}/privkey.pem"
        chmod 644 "/etc/letsencrypt/live/${saved_domain}/fullchain.pem" "/etc/letsencrypt/live/${saved_domain}/privkey.pem"
      fi
      if docker exec "$cname" nginx -t 2>/dev/null; then
        docker exec "$cname" nginx -s reload 2>/dev/null && echo "[ok] Внешний docker-nginx (${cname}) успешно перезагружен" || {
          echo "[warn] Не удалось перезагрузить через reload, перезапускаю контейнер..."
          docker restart "$cname" &>/dev/null && echo "[ok] Внешний docker-nginx (${cname}) перезапущен" || echo "[warn] Не удалось перезапустить контейнер"
        }
      else
        echo "[error] Ошибка конфигурации внешнего docker-nginx (${cname})! Перезапускаю контейнер..."
        docker restart "$cname" &>/dev/null && echo "[ok] Внешний docker-nginx (${cname}) перезапущен" || echo "[warn] Не удалось перезапустить контейнер"
      fi
    fi
  fi
fi

echo "[ok] Обновление сертификатов и reload сервисов успешно завершены"