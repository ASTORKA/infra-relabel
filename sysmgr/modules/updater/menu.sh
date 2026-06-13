#!/bin/bash
# ============================================================ #
# ==             UPDATER: АВТООБНОВЛЯТОР                    == #
# ============================================================ #
#  ( РОДИТЕЛЬ | КЛАВИША | НАЗВАНИЕ | ФУНКЦИЯ | ПОРЯДОК | ГРУППА | ОПИСАНИЕ )
# @menu.manifest
# @item( main | 9 | 💣 АВТООБНОВЛЯТОР СЕРВИСОВ | show_updater_menu | 50 | 3 | Централизованное обновление всех компонентов системы. )
# @item( updater | 1 | 🚀 ЗАПУСТИТЬ ОБНОВЛЕНИЕ | updater_run | 10 | 1 | Начать процесс обновления всех настроенных сервисов. )
# @item( updater | 2 | ⚙️ НАСТРОИТЬ СЕРВИСЫ | updater_config | 20 | 2 | Управление списком сервисов, сканирование и выбор стратегий. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Загружаем ядро автообновлятора и конфиг-менеджер
if [ -f "${SCRIPT_DIR}/modules/updater/core.sh" ]; then
    source "${SCRIPT_DIR}/modules/updater/core.sh"
fi

if [ -f "${SCRIPT_DIR}/modules/updater/config_manager.sh" ]; then
    source "${SCRIPT_DIR}/modules/updater/config_manager.sh"
fi

show_updater_menu() {
    while true; do
        clear
        menu_header "💣 АВТООБНОВЛЯТОР СЕРВИСОВ (UPDATER)" 60 "${C_MAGENTA}"
        
        echo ""
        render_menu_items "updater"
        echo ""
        
        printf_menu_option "b" "🔙 Назад в главное меню" "${C_CYAN}"
        print_separator "─" 60
        
        local choice
        choice=$(safe_read "Твой выбор" "") || return 130
        
        if [[ "$choice" == "b" || "$choice" == "B" ]]; then
            break
        fi
        
        local action
        action=$(get_menu_action "updater" "$choice")
        
        if [[ -n "$action" ]]; then
            eval "$action"
            wait_for_enter
        else
            printf_error "Нет такого пункта."
            sleep 1
        fi
    done
}

updater_run() {
    run_update_sequence
}

updater_config() {
    show_updater_config_menu
}
