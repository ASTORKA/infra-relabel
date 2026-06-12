#!/usr/bin/env bash
#
# relabel.sh — переименование docker-контейнеров под нейтральные имена.
#
# Зачем: чтобы в `docker ps` (и в метках compose) хостинг не видел
# характерных VPN-имён (remnanode, caddy-selfsteal и т.п.).
#
# Что делает:
#   - находит compose-файл каждого контейнера через его docker-метки;
#   - правит в нём `container_name:` на маскирующее имя (с бэкапом);
#   - делает `docker rename` живому контейнеру (без пересоздания / простоя);
#   - запоминает обратную карту, чтобы можно было откатить.
#
# Команды:
#   ./relabel.sh status     показать текущие имена и что уже замаскировано
#   ./relabel.sh apply      применить маскировку (по names.conf)
#   ./relabel.sh restore    откатить к исходным именам
#   ./relabel.sh ps         показать процессы внутри контейнеров
#
set -euo pipefail

# Разрешаем симлинки, чтобы SCRIPT_DIR указывал на реальный каталог репозитория
# (где лежат names.conf и .state/), даже если вызвали через /usr/local/bin/relabel.
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
CONF="${RELABEL_CONF:-$SCRIPT_DIR/names.conf}"
STATE_DIR="$SCRIPT_DIR/.state"
STATE_FILE="$STATE_DIR/applied.map"      # строки: decoy|orig|compose_file
BACKUP_DIR="$STATE_DIR/backups"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# --- утилиты ---------------------------------------------------------------

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

die() { c_red "Ошибка: $*" >&2; exit 1; }

trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

need_docker() { command -v docker >/dev/null 2>&1 || die "docker не найден в PATH"; }

# Поддержка как `docker compose`, так и старого `docker-compose` (для справки).
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"; fi
}

# Заменить значение container_name в файле (сохраняя кавычки/отступ).
# $1=file $2=искомое_имя $3=новое_имя
replace_container_name() {
  local file="$1" from="$2" to="$3" tmp
  tmp="$(mktemp)"
  sed -E "s/(container_name:[[:space:]]*[\"']?)${from}([\"']?[[:space:]]*)\$/\1${to}\2/" "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Вставить container_name под сервис, если его в файле нет.
# $1=file $2=service $3=name
insert_container_name() {
  local file="$1" svc="$2" name="$3" tmp
  tmp="$(mktemp)"
  awk -v svc="$svc" -v name="$name" '
    !done && $0 ~ "^[[:space:]]+" svc ":[[:space:]]*$" {
      print
      match($0, /^[[:space:]]*/); indent=substr($0,1,RLENGTH)
      print indent "  container_name: " name
      done=1; next
    }
    { print }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Метка compose у контейнера. $1=container $2=label
docker_label() {
  docker inspect -f "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true
}

# Путь к compose-файлу контейнера (абсолютный). Пусто — если не из compose.
compose_file_of() {
  local c="$1" cfg wd first
  cfg="$(docker_label "$c" com.docker.compose.project.config_files)"
  wd="$(docker_label "$c" com.docker.compose.project.working_dir)"
  [ -z "$cfg" ] && { echo ""; return; }
  # config_files может быть списком через запятую — берём первый.
  first="${cfg%%,*}"
  first="$(trim "$first")"
  case "$first" in
    /*) echo "$first" ;;
    *)  [ -n "$wd" ] && echo "$wd/$first" || echo "$first" ;;
  esac
}

# --- парсинг конфигурации ---------------------------------------------------

declare -a ORIG_LIST DECOY_LIST
load_conf() {
  [ -f "$CONF" ] || die "нет файла конфигурации: $CONF"
  ORIG_LIST=(); DECOY_LIST=()
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -z "$(trim "$line")" ] && continue
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    [ -z "$key" ] && continue
    [ -z "$val" ] && continue
    ORIG_LIST+=("$key")
    DECOY_LIST+=("$val")
  done <"$CONF"
  [ "${#ORIG_LIST[@]}" -gt 0 ] || die "в $CONF нет ни одной пары имён"
}

# Найти реальное имя контейнера: либо orig, либо уже применённый decoy.
resolve_container() {
  local orig="$1" decoy="$2"
  if docker container inspect "$decoy" >/dev/null 2>&1; then echo "$decoy"; return 0; fi
  if docker container inspect "$orig"  >/dev/null 2>&1; then echo "$orig";  return 0; fi
  echo ""; return 1
}

# --- команды ----------------------------------------------------------------

cmd_status() {
  load_conf
  printf '%-22s %-16s %-14s %s\n' "ИСХОДНОЕ" "МАСКА" "СОСТОЯНИЕ" "COMPOSE-ФАЙЛ"
  printf '%-22s %-16s %-14s %s\n' "--------" "-----" "---------" "------------"
  local i orig decoy cur file state
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"
    cur="$(resolve_container "$orig" "$decoy" || true)"
    file=""
    [ -n "$cur" ] && file="$(compose_file_of "$cur")"
    if [ -z "$cur" ]; then
      state="нет контейнера"
    elif [ "$cur" = "$decoy" ]; then
      state="замаскирован"
    else
      state="открыт"
    fi
    printf '%-22s %-16s %-14s %s\n' "$orig" "$decoy" "$state" "${file:-—}"
  done
}

cmd_apply() {
  load_conf
  : >"$STATE_FILE.tmp"
  local i orig decoy cur file svc
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"

    cur="$(resolve_container "$orig" "$decoy" || true)"
    if [ -z "$cur" ]; then
      c_yel "· $orig — контейнер не найден, пропуск"
      continue
    fi
    if [ "$cur" = "$decoy" ]; then
      c_dim "· $orig → $decoy уже применено"
      file="$(compose_file_of "$cur")"
      echo "$decoy|$orig|${file:-}" >>"$STATE_FILE.tmp"
      continue
    fi
    if docker container inspect "$decoy" >/dev/null 2>&1; then
      die "имя $decoy уже занято другим контейнером"
    fi

    file="$(compose_file_of "$cur")"
    if [ -n "$file" ] && [ -f "$file" ]; then
      # бэкап файла (один раз на файл)
      local bname; bname="$(echo "$file" | sed 's#/#_#g')"
      [ -f "$BACKUP_DIR/$bname" ] || cp "$file" "$BACKUP_DIR/$bname"

      if grep -Eq "container_name:[[:space:]]*[\"']?${orig}[\"']?" "$file"; then
        replace_container_name "$file" "$orig" "$decoy"
      else
        svc="$(docker_label "$cur" com.docker.compose.service)"
        if [ -n "$svc" ]; then
          insert_container_name "$file" "$svc" "$decoy"
        else
          c_yel "  ! не нашёл container_name и сервис в $file — правлю только живой контейнер"
        fi
      fi
    else
      c_yel "  ! $orig не из docker compose — только rename, при пересоздании имя вернётся"
    fi

    docker rename "$cur" "$decoy"
    c_grn "· $orig → $decoy"
    echo "$decoy|$orig|${file:-}" >>"$STATE_FILE.tmp"
  done
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo
  c_grn "Готово. Проверка: docker ps --format '{{.Names}}\t{{.Image}}'"
}

cmd_restore() {
  [ -f "$STATE_FILE" ] || die "нет сохранённого состояния ($STATE_FILE) — нечего откатывать"
  local decoy orig file
  while IFS='|' read -r decoy orig file; do
    [ -z "$decoy" ] && continue
    if [ -n "$file" ] && [ -f "$file" ]; then
      if grep -Eq "container_name:[[:space:]]*[\"']?${decoy}[\"']?" "$file"; then
        replace_container_name "$file" "$decoy" "$orig"
      fi
    fi
    if docker container inspect "$decoy" >/dev/null 2>&1; then
      docker rename "$decoy" "$orig"
      c_grn "· $decoy → $orig"
    elif docker container inspect "$orig" >/dev/null 2>&1; then
      c_dim "· $orig уже с исходным именем"
    else
      c_yel "· $decoy — контейнер не найден"
    fi
  done <"$STATE_FILE"
  rm -f "$STATE_FILE"
  echo
  c_grn "Откат завершён."
}

cmd_ps() {
  load_conf
  local i orig decoy cur
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"
    cur="$(resolve_container "$orig" "$decoy" || true)"
    [ -z "$cur" ] && { c_yel "· $orig/$decoy — нет контейнера"; continue; }
    c_grn "=== $cur ==="
    docker top "$cur" -eo pid,comm,args 2>/dev/null || docker top "$cur"
    echo
  done
  c_dim "Подсказка: процессы хоста — ps -ef ; дерево — pstree -p ; вживую — htop"
}

usage() {
  cat <<'EOF'
relabel.sh — маскировка имён docker-контейнеров

  ./relabel.sh status     показать текущие имена и состояние маскировки
  ./relabel.sh apply       применить имена из names.conf
  ./relabel.sh restore     откатить к исходным именам
  ./relabel.sh ps          показать процессы внутри контейнеров

Карта имён — в names.conf. Бэкапы compose-файлов и карта отката
складываются в .state/ (не коммитятся).
EOF
}

# --- точка входа ------------------------------------------------------------

need_docker
case "${1:-}" in
  status)  cmd_status ;;
  apply)   cmd_apply ;;
  restore) cmd_restore ;;
  ps)      cmd_ps ;;
  ""|-h|--help|help) usage ;;
  *) die "неизвестная команда: $1 (см. --help)" ;;
esac
