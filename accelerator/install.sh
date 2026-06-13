#!/usr/bin/env bash
#
# sysguard — ⚡ оптимизатор + 🩺 диагностика + 🛡 защита panel/VPN-ноды.
#
#   sudo bash install.sh              — меню
#   sudo bash install.sh optimize     — ⚡ XanMod+BBRv3 + тюнинг
#   sudo bash install.sh protect      — 🛡 nftables + CrowdSec
#   sudo bash install.sh diagnose     — 🩺 диагностика (read-only)
#   sudo bash install.sh all          — optimize → protect → diagnose
#   sudo bash install.sh rollback [optimize|protect|all]
#
# curl-bash:
#   curl -fsSL https://raw.githubusercontent.com/ASTORKA/infra-relabel/main/accelerator/install.sh | sudo bash -s all
#   # прод: пиньте тег (компрометация ветки main тогда не утечёт сразу на весь флот):
#   export SG_REF=v2.1; curl -fsSL "https://raw.githubusercontent.com/ASTORKA/infra-relabel/$SG_REF/accelerator/install.sh" | sudo -E bash -s all

set -euo pipefail
# ${BASH_SOURCE[0]:-$0}: при запуске через curl|bash (bash -s) BASH_SOURCE пуст, и под
# set -u голый ${BASH_SOURCE[0]} даёт «unbound variable». Фоллбэк на $0 убирает шум.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
# SG_REF — ветка/тег для curl|bash-режима (по умолчанию main). Для прода пиньте тег.
SG_REF="${SG_REF:-main}"
# SG_REF уходит в URL модулей — запрещаем path-traversal/инъекцию (увод на чужой репо).
[[ "$SG_REF" =~ ^[A-Za-z0-9._/-]+$ && "$SG_REF" != *..* ]] || { echo "[x] SG_REF '$SG_REF' невалиден"; exit 1; }
REPO_URL="${SG_REPO_URL:-https://raw.githubusercontent.com/ASTORKA/infra-relabel/$SG_REF/accelerator}"

# Опц. проверка подписи модулей в curl|bash-режиме (supply-chain hardening). По умолч.
# выкл. SG_REQUIRE_SIG=1 + minisign-ключ (SG_MINISIGN_PUBKEY) ИЛИ GPG-отпечаток
# (SG_SIG_FINGERPRINT) → каждый модуль проверяется против .minisig/.asc рядом в репо.
SG_REQUIRE_SIG="${SG_REQUIRE_SIG:-0}"
SG_MINISIGN_PUBKEY="${SG_MINISIGN_PUBKEY:-}"
SG_SIG_FINGERPRINT="${SG_SIG_FINGERPRINT:-}"
verify_sig() {  # verify_sig <файл> <url-без-расширения>
    local file="$1" url="$2"
    if [[ -n "$SG_MINISIGN_PUBKEY" ]] && command -v minisign >/dev/null 2>&1; then
        curl -fsSL "$url.minisig" -o "$file.minisig" 2>/dev/null || { echo "[x] нет .minisig для $(basename "$file")"; return 1; }
        minisign -V -P "$SG_MINISIGN_PUBKEY" -m "$file" >/dev/null 2>&1
    elif [[ -n "$SG_SIG_FINGERPRINT" ]] && command -v gpg >/dev/null 2>&1; then
        curl -fsSL "$url.asc" -o "$file.asc" 2>/dev/null || { echo "[x] нет .asc для $(basename "$file")"; return 1; }
        gpg --verify "$file.asc" "$file" 2>&1 | grep -q "${SG_SIG_FINGERPRINT// /}"
    else
        echo "[x] SG_REQUIRE_SIG=1, но нет minisign+SG_MINISIGN_PUBKEY или gpg+SG_SIG_FINGERPRINT"; return 1
    fi
}

# curl|bash — подтянуть модули
if [[ ! -d "$SCRIPTS" ]]; then
    SCRIPTS="$(mktemp -d)/scripts"; mkdir -p "$SCRIPTS/lib"
    echo "[*] Скачиваю модули из $REPO_URL ..."
    for f in lib/common.sh optimize.sh protect.sh diagnose.sh rollback.sh; do
        curl -fsSL "$REPO_URL/scripts/$f" -o "$SCRIPTS/$f" || { echo "[x] Не скачал $f"; exit 1; }
        if [[ "$SG_REQUIRE_SIG" == "1" ]]; then
            verify_sig "$SCRIPTS/$f" "$REPO_URL/scripts/$f" \
                && echo "[+] подпись $f валидна" \
                || { echo "[x] подпись $f НЕ прошла — отказ (SG_REQUIRE_SIG=1)"; exit 1; }
        fi
    done
fi

# shellcheck source=scripts/lib/common.sh
. "$SCRIPTS/lib/common.sh"
require_root
detect_os

run_optimize() { bash "$SCRIPTS/optimize.sh"; }
run_protect()  { bash "$SCRIPTS/protect.sh"; }
run_diagnose() { bash "$SCRIPTS/diagnose.sh" "$@"; }
run_rollback() { bash "$SCRIPTS/rollback.sh" "${1:-all}"; }

show_menu() {
    clear 2>/dev/null || true
    cat <<'BANNER'
┌────────────────────────────────────────────────────┐
│            ⚡ sysguard ⚡                    │
│   Оптимизация · Диагностика · Защита VPN-ноды       │
├────────────────────────────────────────────────────┤
│                                                      │
│   1) ⚡ Оптимизатор                                  │
│        XanMod (BBRv3) + sysctl + RPS/RFS +           │
│        лимиты + swap + NIC + governor                │
│                                                      │
│   2) 🛡 Защита                                       │
│        nftables (AntiScan/flag-drop/anti-spoof/      │
│        SYN+UDP-flood/ssh-flood) + CrowdSec bouncer   │
│                                                      │
│   3) 🩺 Диагностика (read-only)                      │
│                                                      │
│   4) 🚀 Всё сразу (1 → 2 → 3)                        │
│                                                      │
│   5) ↩️  Откат                                       │
│                                                      │
│   0) Выход                                           │
│                                                      │
└────────────────────────────────────────────────────┘
BANNER
    read -r -p "Выбор: " choice
    case "$choice" in
        1) run_optimize ;;
        2) run_protect ;;
        3) run_diagnose ;;
        4) run_optimize; run_protect; run_diagnose ;;
        5)
            echo "  a) optimize   b) protect   c) всё"
            read -r -p "Что откатить? [c]: " r
            case "$r" in a|A) run_rollback optimize ;; b|B) run_rollback protect ;; *) run_rollback all ;; esac
            ;;
        0) exit 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

case "${1:-}" in
    optimize) run_optimize ;;
    protect)  run_protect ;;
    diagnose|diag) shift; run_diagnose "$@" ;;
    all)      run_optimize; run_protect; run_diagnose ;;
    rollback) run_rollback "${2:-all}" ;;
    "")       show_menu ;;
    -h|--help) sed -n '2,18p' "$0" ;;
    *) err "Неизвестная команда: $1"; sed -n '2,18p' "$0"; exit 1 ;;
esac
