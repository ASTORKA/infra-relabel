#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Единый управляющий модуль VPN Gateway.
#
# Назначение:
# - работать как самостоятельная интерактивная "решала";
# - работать как встраиваемый модуль для Sysmgr.
#
# Подход:
# - единая точка входа;
# - стабильные action-имена для внешнего диспетчера;
# - явные подтверждения для опасных операций.
# ============================================================

MODULE_NAME="vpn-gateway"
MODULE_VERSION="1.0.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

YES_FLAG=false
YES_PURGE_FLAG=false
NON_INTERACTIVE=false

log() { echo "[gatewayctl] $*"; }
warn() { echo "[warn] $*"; }
err() { echo "[error] $*" >&2; }

require_script() {
  local script_path="$1"
  if [[ ! -x "${script_path}" ]]; then
    err "Не найден исполняемый скрипт: ${script_path}"
    exit 1
  fi
}

confirm_yes_phrase() {
  local phrase="$1"
  local answer=""
  read -r -p "Введите ${phrase} для подтверждения: " answer
  [[ "${answer}" == "${phrase}" ]]
}

need_yes_or_prompt() {
  local phrase="$1"
  local mode_name="$2"

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    case "${phrase}" in
      YES)
        if [[ "${YES_FLAG}" != "true" ]]; then
          err "Для ${mode_name} в non-interactive режиме нужен флаг --yes"
          return 1
        fi
        ;;
      YES-PURGE)
        if [[ "${YES_PURGE_FLAG}" != "true" ]]; then
          err "Для ${mode_name} в non-interactive режиме нужен флаг --yes-purge"
          return 1
        fi
        ;;
      *)
        err "Неизвестная фраза подтверждения: ${phrase}"
        return 1
        ;;
    esac
    return 0
  fi

  confirm_yes_phrase "${phrase}"
}

run_install() {
  require_script "${SCRIPTS_DIR}/install.sh"
  "${SCRIPTS_DIR}/install.sh"
}

run_prod() {
  require_script "${SCRIPTS_DIR}/run-prod.sh"
  "${SCRIPTS_DIR}/run-prod.sh"
}

run_tests() {
  require_script "${SCRIPTS_DIR}/full-test.sh"
  "${SCRIPTS_DIR}/full-test.sh"
}

run_ensure_certs() {
  require_script "${SCRIPTS_DIR}/ensure-certs.sh"
  "${SCRIPTS_DIR}/ensure-certs.sh"
}

run_renew_certs() {
  require_script "${SCRIPTS_DIR}/renew-certs.sh"
  "${SCRIPTS_DIR}/renew-certs.sh"
}

run_install_cron() {
  require_script "${SCRIPTS_DIR}/install-renew-cron.sh"
  "${SCRIPTS_DIR}/install-renew-cron.sh"
}

run_uninstall_dry() {
  require_script "${SCRIPTS_DIR}/uninstall.sh"
  "${SCRIPTS_DIR}/uninstall.sh" --dry-run
}

run_uninstall_execute() {
  require_script "${SCRIPTS_DIR}/uninstall.sh"
  warn "Это удалит контейнеры и сетевые ресурсы проекта (без purge данных)."
  if ! need_yes_or_prompt "YES" "uninstall"; then
    err "Операция отменена"
    return 1
  fi
  "${SCRIPTS_DIR}/uninstall.sh" --yes
}

run_uninstall_purge() {
  require_script "${SCRIPTS_DIR}/uninstall.sh"
  warn "Это удалит контейнеры и локальные данные edge (certs/logs/.env.edge)."
  if ! need_yes_or_prompt "YES-PURGE" "uninstall-purge"; then
    err "Операция отменена"
    return 1
  fi
  "${SCRIPTS_DIR}/uninstall.sh" --yes --purge-data
}

show_status() {
  cd "${ROOT_DIR}"
  log "Проверка docker-сервисов проекта"

  local dc_bin=""
  if docker compose version &>/dev/null 2>&1; then
    dc_bin="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    dc_bin="docker-compose"
  else
    warn "docker-compose не найден"
    return 1
  fi

  # Гарантируем наличие .env.edge (нужен для парсинга docker-compose.edge.yml)
  if [[ ! -f "${ROOT_DIR}/edge/.env.edge" ]]; then
    mkdir -p "${ROOT_DIR}/edge"
    printf 'EDGE_DOMAIN=\nEDGE_HTTP_PORT=80\nEDGE_HTTPS_PORT=443\n' > "${ROOT_DIR}/edge/.env.edge"
  fi

  ${dc_bin} -f docker-compose.yml -f docker-compose.edge.yml ps || true
}


show_manifest() {
  cat <<EOF
module=${MODULE_NAME}
version=${MODULE_VERSION}
entrypoint=./scripts/gatewayctl.sh
default_mode=interactive
supports_non_interactive=true
dangerous_actions=uninstall,uninstall-purge
EOF
}

list_actions() {
  cat <<'EOF'
install
run
test
certs-ensure
certs-renew
certs-cron
uninstall-dry
uninstall
uninstall-purge
status
EOF
}

usage() {
  cat <<'EOF'
Использование:
  ./scripts/gatewayctl.sh
  ./scripts/gatewayctl.sh <команда> [флаги]

Режимы:
  (без команды)        Интерактивное меню
  <команда>            Запуск конкретного action

Флаги:
  --non-interactive    Запрет интерактивных вопросов (для встраивания в решалу)
  --yes                Подтверждение для action uninstall
  --yes-purge          Подтверждение для action uninstall-purge
  -h, --help           Показать справку

Команды:
  menu                 Открыть интерактивное меню
  install              Полная автоустановка и проверка
  run                  Запуск production-стека
  test                 Запуск тестов/проверок
  certs-ensure         Выпуск/проверка сертификатов
  certs-renew          Обновление сертификатов и reload nginx
  certs-cron           Установка cron для cert-renew
  uninstall-dry        Безопасный предпросмотр удаления
  uninstall            Реальное удаление (нужен --yes в non-interactive)
  uninstall-purge      Реальное удаление + purge (нужен --yes-purge в non-interactive)
  status               Статус docker-compose сервисов
  manifest             Технический манифест модуля для внешней решалы
  list-actions         Список action-имен для внешнего диспетчера
  help                 Показать эту справку
EOF
}

dispatch_command() {
  local cmd="$1"
  case "${cmd}" in
    menu) interactive_menu ;;
    install) run_install ;;
    run) run_prod ;;
    test) run_tests ;;
    certs-ensure) run_ensure_certs ;;
    certs-renew) run_renew_certs ;;
    certs-cron) run_install_cron ;;
    uninstall-dry) run_uninstall_dry ;;
    uninstall) run_uninstall_execute ;;
    uninstall-purge) run_uninstall_purge ;;
    status) show_status ;;
    manifest) show_manifest ;;
    list-actions) list_actions ;;
    help|-h|--help) usage ;;
    *)
      err "Неизвестная команда: ${cmd}"
      usage
      return 1
      ;;
  esac
}

interactive_menu() {
  while true; do
    cat <<'EOF'

============= VPN Gateway Module Control =============
  1) Install: автоустановка + проверки
  2) Run: запуск production-стека
  3) Test: тесты и проверки
  4) Ensure certs: выпуск/проверка сертификатов
  5) Renew certs: обновление и reload nginx
  6) Install cert renew cron
  7) Uninstall DRY-RUN (без удаления)
  8) Uninstall EXECUTE (удаление контейнеров)
  9) Uninstall PURGE (удаление контейнеров + данных)
 10) Status docker-compose
 11) Manifest (для встраивания)
 12) List actions (для диспетчера)
  0) Exit
======================================================
EOF
    read -r -p "Выберите действие [0-12]: " choice
    case "${choice}" in
      1) run_install ;;
      2) run_prod ;;
      3) run_tests ;;
      4) run_ensure_certs ;;
      5) run_renew_certs ;;
      6) run_install_cron ;;
      7) run_uninstall_dry ;;
      8) run_uninstall_execute || true ;;
      9) run_uninstall_purge || true ;;
      10) show_status ;;
      11) show_manifest ;;
      12) list_actions ;;
      0)
        log "Выход"
        break
        ;;
      *) warn "Неизвестный пункт: ${choice}" ;;
    esac
  done
}

parse_args() {
  local cmd="menu"

  if [[ "$#" -gt 0 && "${1:-}" != "" && "${1#-}" == "$1" ]]; then
    cmd="$1"
    shift
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        NON_INTERACTIVE=true
        ;;
      --yes)
        YES_FLAG=true
        ;;
      --yes-purge)
        YES_PURGE_FLAG=true
        ;;
      -h|--help)
        cmd="help"
        ;;
      *)
        err "Неизвестный флаг/аргумент: $1"
        return 1
        ;;
    esac
    shift
  done

  echo "${cmd}"
}

main() {
  local cmd
  cmd="$(parse_args "$@")"
  dispatch_command "${cmd}"
}

main "$@"
