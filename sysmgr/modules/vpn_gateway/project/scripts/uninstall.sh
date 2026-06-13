#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Безопасное удаление ресурсов VPN Gateway.
# По умолчанию работает в DRY-RUN (только показывает действия).
#
# Режимы:
#   ./scripts/uninstall.sh --dry-run         # только показать
#   ./scripts/uninstall.sh --yes             # выполнить удаление
#   ./scripts/uninstall.sh --yes --purge-data # + удалить локальные certs/logs/.env.edge
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=true
ASSUME_YES=false
PURGE_DATA=false

log() { echo "[uninstall] $*"; }
warn() { echo "[warn] $*"; }
err() { echo "[error] $*" >&2; }

usage() {
  cat <<'EOF'
Использование:
  ./scripts/uninstall.sh [--dry-run] [--yes] [--purge-data]

Опции:
  --dry-run      Показать, что будет удалено (режим по умолчанию)
  --yes          Выполнить удаление без интерактивного вопроса
  --purge-data   Дополнительно удалить локальные данные edge:
                 edge/certs/*, edge/logs/*, edge/.env.edge
  -h, --help     Показать справку
EOF
}

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --yes)
      DRY_RUN=false
      ASSUME_YES=true
      ;;
    --purge-data)
      PURGE_DATA=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Неизвестный аргумент: $arg"
      usage
      exit 1
      ;;
  esac
done

if docker compose version &>/dev/null 2>&1; then
  DC_BIN="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_BIN="docker-compose"
else
  err "Не найден ни 'docker compose', ни 'docker-compose'"
  exit 1
fi

COMPOSE_CMD="${DC_BIN} -f docker-compose.yml -f docker-compose.edge.yml"
cd "${ROOT_DIR}"

log "Проект: ${ROOT_DIR}"
log "Режим: $([[ "${DRY_RUN}" == "true" ]] && echo 'DRY-RUN' || echo 'EXECUTE')"

if [[ "${DRY_RUN}" == "false" && "${ASSUME_YES}" != "true" ]]; then
  echo
  warn "Будут остановлены и удалены контейнеры, сеть и orphan-ресурсы проекта."
  if [[ "${PURGE_DATA}" == "true" ]]; then
    warn "Также будут удалены локальные файлы certs/logs/.env.edge."
  fi
  echo
  read -r -p "Подтвердите удаление (введите YES): " answer
  if [[ "${answer}" != "YES" ]]; then
    err "Отменено пользователем"
    exit 1
  fi
fi

log "Останавливаю и удаляю docker-compose ресурсы проекта..."

# docker-compose.edge.yml ссылается на edge/.env.edge для подстановки переменных.
# Если файл отсутствует (стек ещё не запускался или был удалён) — docker-compose
# падает с "Couldn't find env file" и не может даже остановить контейнеры.
# Создаём минимальный stub чтобы down прошёл в любом случае.
if [[ ! -f "${ROOT_DIR}/edge/.env.edge" ]]; then
    mkdir -p "${ROOT_DIR}/edge"
    printf 'EDGE_DOMAIN=\nEDGE_HTTP_PORT=80\nEDGE_HTTPS_PORT=443\n' > "${ROOT_DIR}/edge/.env.edge"
    log "Создан stub edge/.env.edge (стек не был запущен ранее)"
fi

run_cmd "${COMPOSE_CMD} down --remove-orphans"


if [[ "${PURGE_DATA}" == "true" ]]; then
  log "Очищаю локальные данные edge (certs/logs/.env.edge)..."
  run_cmd "rm -rf edge/certs/*"
  run_cmd "rm -rf edge/logs/*"
  run_cmd "rm -f edge/.env.edge"
fi

log "Готово ✅"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "Это был DRY-RUN. Для реального удаления запустите:"
  if [[ "${PURGE_DATA}" == "true" ]]; then
    log "  ./scripts/gatewayctl.sh uninstall-purge"
  else
    log "  ./scripts/gatewayctl.sh uninstall"
  fi
fi
