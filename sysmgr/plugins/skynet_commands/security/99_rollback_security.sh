#!/bin/bash
#
# TITLE: (System) Rollback Security Settings
# SKYNET_HIDDEN: true
#
# Откатывает настройки безопасности к стандартным (включает пароли, ослабляет лимиты).

# --- Standard helpers for Skynet plugins ---
set -e
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m';
info() { echo -e "${C_RESET}[i] $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
err()  { echo -e "${C_RED}[✗] $*${C_RESET}"; exit 1; }
# --- End of helpers ---

SSH_CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="${SSH_CONFIG_FILE}.bak_sysmgr_rollback"

info "Начинаю откат настроек безопасности..."

# --- 1. Восстановление SSH (Пароли) ---
if [[ -f "$SSH_CONFIG_FILE" ]]; then
    info "Включаю вход по паролю в SSH..."
    
    # Делаем бекап перед правкой
    cp "$SSH_CONFIG_FILE" "$BACKUP_FILE"
    
    # Меняем настройки на стандартные/ослабленные
    sed -i -e 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG_FILE"
    sed -i -e 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SSH_CONFIG_FILE"
    sed -i -e 's/^MaxAuthTries.*/MaxAuthTries 10/' "$SSH_CONFIG_FILE"
    
    # Если строк не было, добавляем их (на всякий случай)
    grep -q "^PasswordAuthentication" "$SSH_CONFIG_FILE" || echo "PasswordAuthentication yes" >> "$SSH_CONFIG_FILE"
    grep -q "^PermitRootLogin" "$SSH_CONFIG_FILE" || echo "PermitRootLogin yes" >> "$SSH_CONFIG_FILE"
    
    info "Перезапускаю SSH..."
    (systemctl restart sshd || systemctl restart ssh)
    ok "Вход по паролю включен."
else
    err "Конфиг SSH не найден!"
fi

# --- 2. Firewall (UFW) ---
if command -v ufw &>/dev/null; then
    if ufw status | grep -q "active"; then
        warn "ВНИМАНИЕ: Файрвол UFW сейчас активен."
        # Мы не выключаем его принудительно здесь без запроса, 
        # но в контексте Скайнета мы можем передать флаг DISABLE_UFW
        if [[ "${DISABLE_UFW:-}" == "true" ]]; then
            info "Выключаю UFW по запросу..."
            ufw disable >/dev/null
            ok "UFW выключен."
        fi
    fi
fi

# --- 3. Fail2Ban ---
if systemctl is-active --quiet fail2ban; then
    if [[ "${DISABLE_F2B:-}" == "true" ]]; then
        info "Останавливаю Fail2Ban по запросу..."
        systemctl stop fail2ban
        systemctl disable fail2ban
        ok "Fail2Ban остановлен и отключен."
    fi
fi

ok "Откат безопасности завершен. Теперь вы можете войти по паролю."
exit 0
