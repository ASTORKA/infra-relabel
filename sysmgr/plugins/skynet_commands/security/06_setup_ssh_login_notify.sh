#!/bin/bash
#
# TITLE: (System) Setup SSH Login Notification
# SKYNET_HIDDEN: true
#
# Настраивает PAM для отправки уведомлений в Telegram при входе по SSH.
# Принимает TG_BOT_TOKEN и TG_CHAT_ID через переменные окружения.

# --- Standard helpers for Skynet plugins ---
set -e # Exit immediately if a command exits with a non-zero status.
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m';
info() { echo -e "${C_RESET}[i] $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
err()  { echo -e "${C_RED}[✗] $*${C_RESET}"; exit 1; }
# --- End of helpers ---

# --- Проверка переменных ---
if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    err "Переменные TG_BOT_TOKEN и TG_CHAT_ID должны быть установлены."
fi

# Включить или выключить. По умолчанию - включить.
ACTION=${1:-enable}

PAM_SSHD_FILE="/etc/pam.d/sshd"
NOTIFY_SCRIPT="/etc/ssh/sysmgr-notify-login.sh"
PAM_CONFIG_LINE="session optional pam_exec.so seteuid $NOTIFY_SCRIPT"

if [[ "$ACTION" == "enable" ]]; then
    info "Включаю уведомления о входе по SSH..."

    # 1. Создаем скрипт уведомлений
    info "Создаю скрипт: $NOTIFY_SCRIPT"
    cat > "$NOTIFY_SCRIPT" << SCRIPT
#!/bin/bash
# Sysmgr: SSH Login Notifier

# Проверяем, что сессия открывается, а не закрывается
if [ "\$PAM_TYPE" != "open_session" ]; then
    exit 0
fi

# Собираем информацию
TOKEN="$TG_BOT_TOKEN"
CHAT_ID="$TG_CHAT_ID"
HOTNAME=\$(hostname -f)
USER="\$PAM_USER"
RHOST="\$PAM_RHOST"
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

# Формируем сообщение
TEXT="*🔓 Вход по SSH*

Сервер: \\\`\$HOSTNAME\
Пользователь: \
\$USER\
С IP адреса: \
\$RHOST\
Время: \
\$DATE"

# URL-кодируем текст
ENCODED_TEXT=\$(printf %s "\$TEXT" | jq -s -R -r @uri)

# Отправляем асинхронно, чтобы не задерживать логин
curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/sendMessage" \
    -d "chat_id=\${CHAT_ID}" \
    -d "text=\${ENCODED_TEXT}" \
    -d "parse_mode=Markdown" > /dev/null 2>&1 &
SCRIPT

    chmod +x "$NOTIFY_SCRIPT"
    ok "Скрипт уведомлений создан."

    # 2. Добавляем вызов в PAM
    if grep -q "$NOTIFY_SCRIPT" "$PAM_SSHD_FILE" 2>/dev/null; then
        ok "PAM уже настроен."
    else
        info "Добавляю вызов скрипта в $PAM_SSHD_FILE..."
        # Добавляем в конец файла
        echo "$PAM_CONFIG_LINE" >> "$PAM_SSHD_FILE"
        ok "Конфигурация PAM обновлена."
    fi
    
    ok "Уведомления о входе по SSH включены."

elif [[ "$ACTION" == "disable" ]]; then
    info "Отключаю уведомления о входе по SSH..."

    # 1. Удаляем вызов из PAM
    if grep -q "$NOTIFY_SCRIPT" "$PAM_SSHD_FILE" 2>/dev/null; then
        info "Удаляю вызов скрипта из $PAM_SSHD_FILE..."
        sed -i "\|$NOTIFY_SCRIPT|d" "$PAM_SSHD_FILE"
        ok "Конфигурация PAM очищена."
    else
        ok "PAM уже был чист."
    fi

    # 2. Удаляем скрипт
    if [[ -f "$NOTIFY_SCRIPT" ]]; then
        rm -f "$NOTIFY_SCRIPT"
        ok "Скрипт уведомлений удален."
    fi

    ok "Уведомления о входе по SSH отключены."
else
    err "Неизвестное действие: $ACTION. Используйте 'enable' или 'disable'."
fi

exit 0
