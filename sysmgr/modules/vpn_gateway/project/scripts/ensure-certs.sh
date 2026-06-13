#!/usr/bin/env bash
set -euo pipefail

# Автоматический выпуск TLS-сертификата Let's Encrypt для рекламного домена.
# Если сертификат уже есть, ничего не делает.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_FILE="${ROOT_DIR}/config/gateway.yml"
CERTS_DIR="${ROOT_DIR}/edge/certs"
ACME_WEBROOT_DIR="${ROOT_DIR}/edge/acme-challenge"
LE_DIR="${ROOT_DIR}/edge/letsencrypt"
FULLCHAIN="${CERTS_DIR}/fullchain.pem"
PRIVKEY="${CERTS_DIR}/privkey.pem"

# Используем venv python если есть (PyYAML может быть только там), иначе системный python3
if [[ -x "${ROOT_DIR}/.venv/bin/python" ]]; then
  PYTHON="${ROOT_DIR}/.venv/bin/python"
else
  PYTHON="python3"
fi

# Определяем docker compose команду заранее — нужна для проверки bind mount
if docker compose version &>/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  echo "[error] Не найден ни 'docker compose', ни 'docker-compose'." >&2; exit 1
fi

mkdir -p "${CERTS_DIR}" "${ACME_WEBROOT_DIR}" "${LE_DIR}"

is_cert_self_signed() {
  local cert_path="$1"
  [[ -f "${cert_path}" ]] || return 1
  
  local cert_subject; cert_subject=$(openssl x509 -noout -subject -in "${cert_path}" 2>/dev/null || echo "")
  local cert_issuer; cert_issuer=$(openssl x509 -noout -issuer -in "${cert_path}" 2>/dev/null || echo "")
  [[ -z "${cert_subject}" ]] && return 1
  
  local clean_subject; clean_subject=$(echo "${cert_subject}" | sed -E 's/^(subject|issuer)=\s*//')
  local clean_issuer; clean_issuer=$(echo "${cert_issuer}" | sed -E 's/^(subject|issuer)=\s*//')
  if [[ -n "${clean_subject}" && "${clean_subject}" == "${clean_issuer}" ]]; then
    return 0 # self-signed
  fi
  
  local sub_hash; sub_hash=$(openssl x509 -noout -subject_hash -in "${cert_path}" 2>/dev/null || echo "1")
  local iss_hash; iss_hash=$(openssl x509 -noout -issuer_hash -in "${cert_path}" 2>/dev/null || echo "2")
  if [[ "${sub_hash}" == "${iss_hash}" ]]; then
    return 0 # self-signed
  fi
  
  return 1 # not self-signed
}

readarray -t CFG_VALUES < <(CFG_FILE="${CFG_FILE}" "${PYTHON}" - <<'PY'
import os
import yaml
from pathlib import Path
cfg = yaml.safe_load(Path(os.environ["CFG_FILE"]).read_text(encoding="utf-8")) or {}
quick = cfg.get("quick_setup", {}) or {}
project = cfg.get("project", {}) or {}
edge = cfg.get("edge", {}) or {}
primary = quick.get("public_domain") or project.get("public_domain") or ""
print(primary)
print(quick.get("acme_email") or "")
print(str(quick.get("acme_enabled", True)).lower())
print(str(edge.get("http_port", 80)))
print(str(edge.get("https_port", 443)))
add_domains = set()
for p in (cfg.get("landing", {}) or {}).get("pages", []):
    for d in p.get("domains", []):
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
  echo "[error] Не задан public_domain в config/gateway.yml" >&2
  exit 1
fi

RENEW_OR_KEEP="--keep-until-expiring"

# Восстанавливаем из персистентного бэкапа если на хосте в edge/certs пусто
PERSIST_CERTS_DIR="/etc/sysmgr-bedolaga/certs/${EDGE_DOMAIN}"
if [[ ! -f "${FULLCHAIN}" || ! -f "${PRIVKEY}" ]]; then
  # Сначала пробуем доменную папку
  if [[ -f "${PERSIST_CERTS_DIR}/fullchain.pem" && -f "${PERSIST_CERTS_DIR}/privkey.pem" ]]; then
    echo "[info] Восстанавливаю существующий Let's Encrypt сертификат из персистентного бэкапа..."
    cp -f "${PERSIST_CERTS_DIR}/fullchain.pem" "${FULLCHAIN}"
    cp -f "${PERSIST_CERTS_DIR}/privkey.pem" "${PRIVKEY}"
    chmod 600 "${PRIVKEY}"
  # Поддерживаем обратную совместимость с общим бэкапом
  elif [[ -f "/etc/sysmgr-bedolaga/certs/fullchain.pem" && -f "/etc/sysmgr-bedolaga/certs/privkey.pem" ]]; then
    echo "[info] Восстанавливаю существующий Let's Encrypt сертификат из устаревшего общего бэкапа..."
    cp -f "/etc/sysmgr-bedolaga/certs/fullchain.pem" "${FULLCHAIN}"
    cp -f "/etc/sysmgr-bedolaga/certs/privkey.pem" "${PRIVKEY}"
    chmod 600 "${PRIVKEY}"
  fi
fi

if [[ -f "${FULLCHAIN}" && -f "${PRIVKEY}" ]]; then
  # Проверяем, совпадает ли домен в сертификате с текущим EDGE_DOMAIN
  cert_domain=$(openssl x509 -noout -subject -in "${FULLCHAIN}" 2>/dev/null | sed -n 's/^.*CN\s*=\s*\(.*\)$/\1/p' || echo "")

  is_self_signed=0
  if is_cert_self_signed "${FULLCHAIN}"; then
    is_self_signed=1
    RENEW_OR_KEEP="--force-renewal"
  fi

  # Проверяем, присутствуют ли все привязанные домены в сертификате
  cert_has_all_domains=1
  for dom in "${EDGE_DOMAIN}" ${EDGE_ADDITIONAL_DOMAINS:-}; do
    if [[ -n "${dom}" ]]; then
      if ! openssl x509 -text -noout -in "${FULLCHAIN}" 2>/dev/null | grep -q "DNS:${dom}" && \
         ! openssl x509 -noout -subject -in "${FULLCHAIN}" 2>/dev/null | grep -q "CN\s*=\s*${dom}\b"; then
        cert_has_all_domains=0
        break
      fi
    fi
  done

  if [[ "${cert_domain}" == "${EDGE_DOMAIN}" || "${cert_domain}" == "*.${EDGE_DOMAIN}" ]] && [[ "${cert_has_all_domains}" -eq 1 ]]; then
    if [[ "${is_self_signed}" -eq 1 ]]; then
      echo "[warn] Обнаружен временный самоподписанный сертификат для ${EDGE_DOMAIN}. Запускаю выпуск настоящего..."
    else
      echo "[ok] Сертификаты уже существуют на хосте и соответствуют домену ${EDGE_DOMAIN} (все домены присутствуют)"

      # Проверяем что контейнер видит файлы через bind mount (защита от неправильного CWD при запуске)
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vpn-edge-nginx"; then
        if ! docker exec vpn-edge-nginx test -f /etc/nginx/certs/fullchain.pem 2>/dev/null; then
          echo "[warn] Контейнер не видит сертификат — bind mount сломан. Пересоздаю контейнер..."
          EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" \
            $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml up -d --force-recreate edge-nginx
          sleep 2
          echo "[ok] Контейнер пересоздан, сертификат доступен"
        else
          echo "[ok] Контейнер видит сертификат — всё в порядке"
        fi
      fi

      exit 0
    fi
  else
    if [[ "${cert_has_all_domains}" -eq 0 ]]; then
      echo "[warn] Найден сертификат, но он не содержит все привязанные дополнительные домены. Перевыпускаю..."
      RENEW_OR_KEEP="--force-renewal"
    else
      echo "[warn] Найден сертификат для другого домена (${cert_domain}). Перевыпускаю для ${EDGE_DOMAIN}..."
    fi
    rm -f "${FULLCHAIN}" "${PRIVKEY}"
  fi
fi

# Временный self-signed сертификат для запуска edge
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
  -keyout "${PRIVKEY}" \
  -out "${FULLCHAIN}" \
  -subj "/CN=${EDGE_DOMAIN}" >/dev/null 2>&1

if [[ "${ACME_ENABLED}" != "true" ]]; then
  echo "[ok] ACME отключен, создан self-signed сертификат для ${EDGE_DOMAIN}"
  exit 0
fi

if [[ "${EDGE_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[warn] Для IP-адреса Let's Encrypt недоступен, оставляю self-signed сертификат"
  exit 0
fi

if [[ -z "${ACME_EMAIL}" || "${ACME_EMAIL}" == "admin@example.com" ]]; then
  echo "[error] Укажите валидный quick_setup.acme_email в config/gateway.yml" >&2
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

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml up -d --build --force-recreate edge-nginx

# Выпуск сертификата через webroot-челлендж
CERTBOT_OK=0

# Очищаем временную или самоподписанную папку live, чтобы Certbot не пропускал выпуск.
# Если в архиве есть валидный сертификат, восстанавливаем его вместо очистки.
for base_le in "/etc/letsencrypt" "${LE_DIR}"; do
  if [[ -d "${base_le}/live/${EDGE_DOMAIN}" ]]; then
    live_cert="${base_le}/live/${EDGE_DOMAIN}/fullchain.pem"
    live_key="${base_le}/live/${EDGE_DOMAIN}/privkey.pem"
    
    needs_clean=0
    if [[ ! -f "${base_le}/renewal/${EDGE_DOMAIN}.conf" ]]; then
      needs_clean=1
    elif is_cert_self_signed "${live_cert}"; then
      needs_clean=1
    fi
    
    if [[ "${needs_clean}" -eq 1 ]]; then
      # Ищем валидный сертификат в архиве, чтобы восстановить
      archive_fullchain=$(ls -v "${base_le}/archive/${EDGE_DOMAIN}/fullchain"*.pem 2>/dev/null | tail -n 1 || echo "")
      archive_privkey=$(ls -v "${base_le}/archive/${EDGE_DOMAIN}/privkey"*.pem 2>/dev/null | tail -n 1 || echo "")
      
      restored=0
      if [[ -n "${archive_fullchain}" && -f "${archive_fullchain}" ]]; then
        if ! is_cert_self_signed "${archive_fullchain}" && openssl x509 -checkend 86400 -noout -in "${archive_fullchain}" &>/dev/null; then
          echo "[info] Найден валидный сертификат в архиве Let's Encrypt (${archive_fullchain}). Восстанавливаю symlinks в live..."
          mkdir -p "${base_le}/live/${EDGE_DOMAIN}"
          ln -sf "../../archive/${EDGE_DOMAIN}/$(basename "${archive_fullchain}")" "${live_cert}"
          ln -sf "../../archive/${EDGE_DOMAIN}/$(basename "${archive_privkey}")" "${live_key}"
          
          archive_cert=$(ls -v "${base_le}/archive/${EDGE_DOMAIN}/cert"*.pem 2>/dev/null | tail -n 1 || echo "")
          archive_chain=$(ls -v "${base_le}/archive/${EDGE_DOMAIN}/chain"*.pem 2>/dev/null | tail -n 1 || echo "")
          [[ -n "${archive_cert}" ]] && ln -sf "../../archive/${EDGE_DOMAIN}/$(basename "${archive_cert}")" "${base_le}/live/${EDGE_DOMAIN}/cert.pem"
          [[ -n "${archive_chain}" ]] && ln -sf "../../archive/${EDGE_DOMAIN}/$(basename "${archive_chain}")" "${base_le}/live/${EDGE_DOMAIN}/chain.pem"
          restored=1
        fi
      fi
      
      if [[ "${restored}" -eq 0 ]]; then
        echo "[info] Очищаю временную/самоподписанную папку live и renewal-конфиг для ${EDGE_DOMAIN} в ${base_le}..."
        rm -rf "${base_le}/live/${EDGE_DOMAIN}" "${base_le}/archive/${EDGE_DOMAIN}" "${base_le}/renewal/${EDGE_DOMAIN}.conf" 2>/dev/null || true
      fi
    fi
  fi
done

# Собираем список доменов для Certbot
d_args=("-d" "${EDGE_DOMAIN}")
if [[ -n "${EDGE_ADDITIONAL_DOMAINS:-}" ]]; then
  for dom in ${EDGE_ADDITIONAL_DOMAINS}; do
    if [[ -n "${dom}" ]]; then
      d_args+=("-d" "${dom}")
    fi
  done
fi

if command -v certbot > /dev/null 2>&1; then
  certbot certonly \
    --webroot \
    -w "${ACME_WEBROOT_DIR}" \
    "${d_args[@]}" \
    --cert-name "${EDGE_DOMAIN}" \
    --email "${ACME_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --rsa-key-size 4096 \
    "${RENEW_OR_KEEP}" && CERTBOT_OK=1 || CERTBOT_OK=0
else
  docker run --rm \
    -v "${ACME_WEBROOT_DIR}:/var/www/acme-challenge" \
    -v "${LE_DIR}:/etc/letsencrypt" \
    certbot/certbot:latest certonly \
      --webroot \
      -w /var/www/acme-challenge \
      "${d_args[@]}" \
      --cert-name "${EDGE_DOMAIN}" \
      --email "${ACME_EMAIL}" \
      --agree-tos \
      --non-interactive \
      --rsa-key-size 4096 \
      "${RENEW_OR_KEEP}" && CERTBOT_OK=1 || CERTBOT_OK=0
fi

if [[ "${CERTBOT_OK}" -eq 0 ]]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "⚠️  CERTBOT НЕ СМОГ ВЫПУСТИТЬ СЕРТИФИКАТ (Connection refused)"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  echo "Причина: LetsEncrypt не может достучаться до http://${EDGE_DOMAIN}:80"
  echo "Это означает, что на порту 80 нет nginx который пробрасывает"
  echo "путь /.well-known/acme-challenge/ к нашему gateway."
  echo ""
  echo "Что нужно сделать:"
  echo ""
  echo "  1. Если у вас remnawave-нода (монолитный nginx.conf.template):"
  echo "     • Добавьте '${EDGE_DOMAIN}  unix:/dev/shm/nginx_http.sock;' в stream map"
  echo "     • Добавьте server-блок в http {} с location ^~ /.well-known/acme-challenge/"
  echo "     • Добавьте volume в docker-compose: $(dirname "${ACME_WEBROOT_DIR}"):/var/www/acme-challenge:ro"
  echo "     • Перезапустите контейнер ноды"
  echo ""
  echo "  2. Если у вас хостовый nginx: добавьте location для ACME challenge"
  echo "     и выполните: nginx -t && systemctl reload nginx"
  echo ""
  echo "  После настройки nginx — повторно выпустите сертификат:"
  echo "  • Через меню [6] Сертификаты"
  echo "  • Или: bash scripts/ensure-certs.sh"
  echo ""
  echo "  Стек работает с временным self-signed сертификатом (HTTPS с ошибкой в браузере)."
  echo "═══════════════════════════════════════════════════════════════"
  exit 0
fi

# Certbot успешно выпустил сертификат — копируем в edge/certs
if command -v certbot > /dev/null 2>&1; then
  cp "/etc/letsencrypt/live/${EDGE_DOMAIN}/fullchain.pem" "${FULLCHAIN}"
  cp "/etc/letsencrypt/live/${EDGE_DOMAIN}/privkey.pem"   "${PRIVKEY}"
else
  cp "${LE_DIR}/live/${EDGE_DOMAIN}/fullchain.pem" "${FULLCHAIN}"
  cp "${LE_DIR}/live/${EDGE_DOMAIN}/privkey.pem"   "${PRIVKEY}"
fi
chmod 600 "${PRIVKEY}"

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml up -d --force-recreate edge-nginx

# Сохраняем сертификаты в персистентное хранилище — переживут git pull и пересоздание контейнеров
PERSIST_CERTS_DIR="/etc/sysmgr-bedolaga/certs/${EDGE_DOMAIN}"

if [[ -f "${FULLCHAIN}" && -f "${PRIVKEY}" ]]; then
  mkdir -p "${PERSIST_CERTS_DIR}" 2>/dev/null && \
    cp -f "${FULLCHAIN}" "${PERSIST_CERTS_DIR}/fullchain.pem" && \
    cp -f "${PRIVKEY}"   "${PERSIST_CERTS_DIR}/privkey.pem"   && \
    chmod 600 "${PERSIST_CERTS_DIR}/privkey.pem" && \
    echo "[ok] Сертификат сохранён в ${PERSIST_CERTS_DIR}" || \
    echo "[warn] Не удалось сохранить сертификат в ${PERSIST_CERTS_DIR}"
fi

if [[ -f "${FULLCHAIN}" ]]; then
  echo "[info] Свойства применённого сертификата:"
  openssl x509 -noout -subject -issuer -dates -in "${FULLCHAIN}" 2>/dev/null || true
fi

echo "[ok] Сертификат Let's Encrypt выпущен и применён для ${EDGE_DOMAIN}"