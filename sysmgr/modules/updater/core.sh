#!/bin/bash
# ============================================================ #
# ==             UPDATER: ЯДРО ОБНОВЛЕНИЯ                   == #
# ============================================================ #

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Зависит от config_manager.sh для загрузки данных
if [ -f "${SCRIPT_DIR}/modules/updater/config_manager.sh" ]; then
    source "${SCRIPT_DIR}/modules/updater/config_manager.sh"
fi

run_update_sequence() {
    load_updater_config
    
    if [ ${#UPDATER_PATHS[@]} -eq 0 ]; then
        # Если конфиг пустой, предлагаем сканирование
        printf_warning "Список сервисов для обновления пуст!"
        if ask_yes_no "Запустить авто-сканирование системы?" "y"; then
            scan_system_for_services
            load_updater_config
            if [ ${#UPDATER_PATHS[@]} -eq 0 ]; then
                printf_error "Всё ещё пусто. Выхожу."
                return
            fi
        else
            return
        fi
    fi
    
    clear
    menu_header "💣 БОЕВОЕ ОБНОВЛЕНИЕ СЕРВИСОВ 💣" 60 "${C_RED}"
    printf_warning "ВНИМАНИЕ! Сейчас начнется остановка и перезапуск контейнеров."
    if ! ask_yes_no "Продолжить?" "y"; then
        printf_info "Обновление отменено."
        return
    fi

    # Разделяем индексы на обычные и веб-серверы (которые должны обновляться и запускаться последними)
    local normal_indices=()
    local late_indices=()
    
    for i in "${!UPDATER_PATHS[@]}"; do
        local dir="${UPDATER_PATHS[$i]}"
        local label="${UPDATER_LABELS[$i]}"
        
        # Проверяем наличие слов nginx или caddy без учета регистра
        if [[ "${dir,,}" == *"nginx"* || "${dir,,}" == *"caddy"* || "${label,,}" == *"nginx"* || "${label,,}" == *"caddy"* ]]; then
            late_indices+=("$i")
        else
            normal_indices+=("$i")
        fi
    done
    
    # Формируем итоговый порядок: сначала обычные, потом веб-серверы
    local ordered_indices=("${normal_indices[@]}" "${late_indices[@]}")
    
    # ЭТАП 1: ГАСИМ СВЕТ
    print_section_title "ЭТАП 1: ОСТАНОВКА КОНТЕЙНЕРОВ (DOWN)"
    for i in "${ordered_indices[@]}"; do
        local dir="${UPDATER_PATHS[$i]}"
        local label="${UPDATER_LABELS[$i]}"
        
        if [ ! -d "$dir" ]; then
            printf_error "Папка не найдена: $dir"
            continue
        fi
        
        printf_info "Останавливаем: ${C_CYAN}$label${C_RESET} ($dir)..."
        (cd "$dir" && docker compose down) &>/dev/null
        if [ $? -eq 0 ]; then 
            printf_ok "Остановлен."
        else 
            printf_error "Ошибка остановки $dir. Проверь логи."
        fi
    done
    
    printf_info "Выметаем мусор из сети Docker (prune)..."
    docker network prune -f &>/dev/null
    printf_ok "Сети очищены."
    echo ""
    
    # ЭТАП 2: ОБНОВЛЕНИЕ И СБОРКА
    print_section_title "ЭТАП 2: ЗАГРУЗКА И СБОРКА"
    for i in "${ordered_indices[@]}"; do
        local dir="${UPDATER_PATHS[$i]}"
        local strategy="${UPDATER_STRATEGIES[$i]}"
        local label="${UPDATER_LABELS[$i]}"
        
        if [ ! -d "$dir" ]; then
            continue
        fi
        
        printf_info "Обработка: ${C_MAGENTA}$label${C_RESET} [Стратегия: $strategy]"
        
        if [[ "$strategy" == "PULL_RESTART" ]]; then
            printf "          ↳ %bЗагрузка образов (docker compose pull)...%b\n" "${C_GRAY}" "${C_RESET}"
            (cd "$dir" && docker compose pull) &>/dev/null
            if [ $? -eq 0 ]; then 
                printf_ok "Образы обновлены."
            else 
                printf_error "Ошибка скачивания образов $dir."
            fi
            
        elif [[ "$strategy" == "BUILD_RESTART" ]]; then
            printf "          ↳ %bGit pull origin main...%b\n" "${C_GRAY}" "${C_RESET}"
            (cd "$dir" && git pull origin main) &>/dev/null
            if [ $? -eq 0 ]; then
                printf_ok "Синхронизация Git успешна."
            else
                printf_warning "Ошибка Git pull. Возможно, репозиторий не обновлен."
            fi
            
            printf "          ↳ %bОчистка кэша сборки (docker builder prune)...%b\n" "${C_GRAY}" "${C_RESET}"
            docker builder prune -a -f &>/dev/null
            
            printf "          ↳ %bСборка образов (build --no-cache)...%b\n" "${C_GRAY}" "${C_RESET}"
            (cd "$dir" && docker compose build --no-cache) &>/dev/null
            if [ $? -eq 0 ]; then
                printf_ok "Сборка завершена успешно."
            else
                printf_error "Ошибка сборки $dir. Проверь логи docker compose build."
            fi
        fi
    done
    echo ""
    
    # ЭТАП 3: ЗАПУСК
    print_section_title "ЭТАП 3: ЗАПУСК КОНТЕЙНЕРОВ (UP)"
    for i in "${ordered_indices[@]}"; do
        local dir="${UPDATER_PATHS[$i]}"
        local label="${UPDATER_LABELS[$i]}"
        
        if [ ! -d "$dir" ]; then
            continue
        fi
        
        printf_info "Запуск: ${C_CYAN}$label${C_RESET}..."
        (cd "$dir" && docker compose up -d) &>/dev/null
        if [ $? -eq 0 ]; then 
            printf_ok "Успешно запущен."
        else 
            printf_error "Ошибка запуска $dir."
        fi
    done
    echo ""
    
    print_section_title "ИТОГ"
    printf_ok "ПРОЦЕСС ОБНОВЛЕНИЯ ЗАВЕРШЕН!"
    printf_info "Если что-то не работает, проверьте логи: docker compose logs -f"
}
