#!/usr/bin/env bash
set -euo pipefail

# Запуск production-стека из одного конфига config/gateway.yml
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_FILE="${ROOT_DIR}/config/gateway.yml"
EDGE_ENV_FILE="${ROOT_DIR}/edge/.env.edge"

if [[ ! -f "${CFG_FILE}" ]]; then
  echo "[error] Не найден конфиг: ${CFG_FILE}" >&2
  exit 1
fi

# Поддерживаем и docker compose (плагин, v2+), и legacy docker-compose
if docker compose version &>/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  DC_CMD="docker-compose"
else
  echo "[error] Не найден ни 'docker compose', ни 'docker-compose'." >&2
  exit 1
fi

# Используем venv python если есть, иначе системный python3
if [[ -x "${ROOT_DIR}/.venv/bin/python" ]]; then
  PYTHON="${ROOT_DIR}/.venv/bin/python"
else
  PYTHON="python3"
fi

# Убеждаемся что PyYAML доступен (установка могла не пройти или venv сломан)
if ! "${PYTHON}" -c "import yaml" 2>/dev/null; then
  echo "[run-prod] PyYAML не найден для ${PYTHON}. Пробую установить через apt..." >&2
  if command -v apt-get > /dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-yaml 2>/dev/null || true
  fi
  if ! "${PYTHON}" -c "import yaml" 2>/dev/null; then
    # Последний шанс: pip
    pip3 install pyyaml --quiet 2>/dev/null || pip3 install pyyaml --quiet --break-system-packages 2>/dev/null || true
  fi
  if ! "${PYTHON}" -c "import yaml" 2>/dev/null; then
    echo "[error] PyYAML недоступен. Установите: apt install python3-yaml" >&2
    exit 1
  fi
fi

readarray -t CFG_VALUES < <(CFG_FILE="${CFG_FILE}" "${PYTHON}" - <<'PY'
import os
import yaml
from pathlib import Path
cfg_path = Path(os.environ["CFG_FILE"])
cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
quick = cfg.get("quick_setup", {}) or {}
project = cfg.get("project", {}) or {}
edge = cfg.get("edge", {}) or {}
primary = quick.get("public_domain") or project.get("public_domain") or ""
print(primary)
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
EDGE_HTTP_PORT="${CFG_VALUES[1]:-80}"
EDGE_HTTPS_PORT="${CFG_VALUES[2]:-443}"
EDGE_ADDITIONAL_DOMAINS="${CFG_VALUES[3]:-}"

if [[ -z "${EDGE_DOMAIN}" ]]; then
  echo "[error] Не задан public_domain в quick_setup или project в config/gateway.yml" >&2
  exit 1
fi

cat > "${EDGE_ENV_FILE}" <<EOF
EDGE_DOMAIN=${EDGE_DOMAIN}
EDGE_ADDITIONAL_DOMAINS=${EDGE_ADDITIONAL_DOMAINS}
EDGE_HTTP_PORT=${EDGE_HTTP_PORT}
EDGE_HTTPS_PORT=${EDGE_HTTPS_PORT}
EOF

cd "${ROOT_DIR}"
echo "[info] Проверяю SSL-сертификаты..."
./scripts/ensure-certs.sh

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml down --remove-orphans || true

# Явно удаляем контейнеры по имени — на случай если они были созданы с другим compose-проектом
# (docker-compose down не трогает «чужие» контейнеры с тем же именем)
for cname in vpn-gateway vpn-edge-nginx; do
  if docker ps -a --format '{{.Names}}' | grep -qx "${cname}"; then
    echo "[info] Удаляю старый контейнер: ${cname}"
    docker rm -f "${cname}" >/dev/null 2>&1 || true
  fi
done

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml up -d --build --force-recreate --remove-orphans

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml restart edge-nginx

echo "[ok] Стек полностью перезапущен. Публичный домен: ${EDGE_DOMAIN}, HTTP: ${EDGE_HTTP_PORT}, HTTPS: ${EDGE_HTTPS_PORT}"