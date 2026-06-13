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
IMG_STATE_FILE="$STATE_DIR/images.map"   # строки: decoy_img|orig_img|file|svc|wd|cfgs
PROJ_STATE_FILE="$STATE_DIR/projects.map" # строки: N|P|D2|D|cfgs
CORE_STATE_FILE="$STATE_DIR/core.map"     # строки: newtag|base|file|svc|wd|cfgs
HOSTPATH_STATE_FILE="$STATE_DIR/hostpaths.map" # строки: cur|oldhost|newhost|file|svc|wd|cfgs
BACKUP_DIR="$STATE_DIR/backups"

DRY_RUN=0   # 1 — только показывать команды, ничего не выполнять

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# --- утилиты ---------------------------------------------------------------

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

die() { c_red "Ошибка: $*" >&2; exit 1; }

trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

need_docker() { command -v docker >/dev/null 2>&1 || die "docker не найден в PATH"; }

# Выполнить команду либо показать её (в dry-run). Аргументы — как есть.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  \033[2m[dry]'; printf ' %q' "$@"; printf '\033[0m\n'
  else
    "$@"
  fi
}

# Заменить подстроку (путь) в файле глобально. $1=file $2=from $3=to
replace_path() {
  local file="$1" from="$2" to="$3" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  sed "s|$from|$to|g" "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

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

# Заменить значение image: в файле (сохраняя кавычки/отступ).
# $1=file $2=искомый_образ $3=новый_образ
replace_image() {
  local file="$1" from="$2" to="$3" tmp
  tmp="$(mktemp)"
  # делимитер | — в именах образов его нет, а / экранировать не нужно
  sed -E "s|(image:[[:space:]]*[\"']?)${from}([\"']?[[:space:]]*)\$|\1${to}\2|" "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Пересоздать один сервис через его же compose-файл(ы), не трогая зависимости.
# $1=service $2=working_dir $3=config_files (через запятую)
compose_up() {
  local svc="$1" wd="$2" cfgs="$3" compose f
  compose="$(compose_cmd)"
  [ -n "$compose" ] || die "нужен docker compose v2 (docker compose ...)"
  local -a fargs=()
  local OLDIFS="$IFS"; IFS=','
  for f in $cfgs; do
    f="$(trim "$f")"; [ -z "$f" ] && continue
    case "$f" in /*) ;; *) f="$wd/$f" ;; esac
    fargs+=( -f "$f" )
  done
  IFS="$OLDIFS"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  \033[2m[dry] (cd %q && %s' "$wd" "$compose"
    printf ' %q' "${fargs[@]}" up -d --no-deps "$svc"; printf ')\033[0m\n'
    return 0
  fi
  ( cd "$wd" && $compose "${fargs[@]}" up -d --no-deps "$svc" )
}

# Найти маскирующее имя по исходному (из загруженной карты). Пусто, если нет.
decoy_for() {
  local key="$1" i
  for i in "${!ORIG_LIST[@]}"; do
    [ "${ORIG_LIST[$i]}" = "$key" ] && { printf '%s' "${DECOY_LIST[$i]}"; return 0; }
  done
  return 1
}

# Заменить host-часть bind-монтирования (часть до первого ":") в compose.
# $1=file $2=старый_host_путь $3=новый_host_путь
replace_bind_host() {
  local file="$1" oldhost="$2" newhost="$3" tmp
  tmp="$(mktemp)"
  sed -E "s#(-[[:space:]]*[\"']?)${oldhost}:#\1${newhost}:#" "$file" >"$tmp"
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
    if [ "$DRY_RUN" = 1 ]; then
      c_grn "· $orig → $decoy  (container_name в ${file:-—})"
      run docker rename "$cur" "$decoy"
      continue
    fi
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
  if [ "$DRY_RUN" = 1 ]; then rm -f "$STATE_FILE.tmp"; echo; c_yel "Это был dry-run."; return; fi
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo
  c_grn "Готово. Проверка: docker ps --format '{{.Names}}\t{{.Image}}'"
}

cmd_restore() {
  [ -f "$STATE_FILE" ] || die "нет сохранённого состояния ($STATE_FILE) — нечего откатывать"
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются."
  local decoy orig file
  while IFS='|' read -r decoy orig file; do
    [ -z "$decoy" ] && continue
    if [ "$DRY_RUN" = 1 ]; then
      c_grn "· $decoy → $orig"
      run docker rename "$decoy" "$orig"
      continue
    fi
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
  [ "$DRY_RUN" = 1 ] && { echo; c_yel "Это был dry-run."; return; }
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

# Маскировка образов: ретег + правка image: в compose + пересоздание сервиса.
# Имя decoy-образа берём из карты: <маска>:<тег_исходного>.
cmd_images() {
  load_conf
  [ "$DRY_RUN" != 1 ] && touch "$IMG_STATE_FILE"
  local i orig decoy cur img tag decoy_img file svc wd cfgs bname
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"
    cur="$(resolve_container "$orig" "$decoy" || true)"
    if [ -z "$cur" ]; then c_yel "· $orig/$decoy — нет контейнера, пропуск"; continue; fi

    img="$(docker inspect -f '{{.Config.Image}}' "$cur" 2>/dev/null || true)"
    [ -z "$img" ] && { c_yel "· $cur — не удалось определить образ"; continue; }

    # уже замаскирован, если образ начинается с маски (ловит и :latest, и :core)
    case "$img" in
      "${decoy}:"*|"${decoy}") c_dim "· $cur образ уже замаскирован ($img)"; continue ;;
    esac

    case "$img" in *:*) tag="${img##*:}" ;; *) tag="latest" ;; esac
    decoy_img="${decoy}:${tag}"
    file="$(compose_file_of "$cur")"
    wd="$(docker_label "$cur" com.docker.compose.project.working_dir)"
    svc="$(docker_label "$cur" com.docker.compose.service)"
    cfgs="$(docker_label "$cur" com.docker.compose.project.config_files)"

    if [ "$DRY_RUN" = 1 ]; then
      c_grn "· $orig: $img → $decoy_img  (ретег + пересоздание $svc)"
      run docker tag "$img" "$decoy_img"
      compose_up "$svc" "$wd" "$cfgs"
      continue
    fi

    docker tag "$img" "$decoy_img"
    if [ -n "$file" ] && [ -f "$file" ] && [ -n "$svc" ] && [ -n "$wd" ]; then
      bname="$(echo "$file" | sed 's#/#_#g')"
      [ -f "$BACKUP_DIR/$bname" ] || cp "$file" "$BACKUP_DIR/$bname"
      if grep -Eq "image:[[:space:]]*[\"']?${img}[\"']?" "$file"; then
        replace_image "$file" "$img" "$decoy_img"
      else
        c_yel "  ! не нашёл строку image: $img в $file — пересоздам с текущим файлом"
      fi
      c_dim "  пересоздаю сервис $svc ($decoy_img)…"
      compose_up "$svc" "$wd" "$cfgs"
      c_grn "· $orig: $img → $decoy_img"
    else
      c_yel "  ! $cur не из docker compose — образ перетегирован ($decoy_img), но контейнер не пересоздан"
    fi
    echo "$decoy_img|$img|${file:-}|${svc:-}|${wd:-}|${cfgs:-}" >>"$IMG_STATE_FILE"
  done
  [ "$DRY_RUN" = 1 ] && { echo; c_yel "Это был dry-run."; return; }
  echo
  c_grn "Готово. Проверка: docker ps --format '{{.Names}}\t{{.Image}}'"
}

cmd_images_restore() {
  [ -f "$IMG_STATE_FILE" ] || die "нет состояния образов ($IMG_STATE_FILE) — нечего откатывать"
  local decoy_img orig_img file svc wd cfgs
  while IFS='|' read -r decoy_img orig_img file svc wd cfgs; do
    [ -z "$decoy_img" ] && continue
    if [ -n "$file" ] && [ -f "$file" ]; then
      if grep -Eq "image:[[:space:]]*[\"']?${decoy_img}[\"']?" "$file"; then
        replace_image "$file" "$decoy_img" "$orig_img"
      fi
    fi
    if [ -n "$svc" ] && [ -n "$wd" ]; then
      compose_up "$svc" "$wd" "$cfgs" || true
    fi
    # снимаем decoy-тег (сам образ остаётся под исходным именем)
    docker rmi "$decoy_img" >/dev/null 2>&1 || true
    c_grn "· $decoy_img → $orig_img"
  done <"$IMG_STATE_FILE"
  rm -f "$IMG_STATE_FILE"
  echo
  c_grn "Откат образов завершён."
}

# Шаг B: переименование compose-проекта + каталога + сети.
# Защита: проекты с именованными томами пропускаются (риск данных).
cmd_project() {
  load_conf
  local compose; compose="$(compose_cmd)"
  [ -n "$compose" ] || die "нужен docker compose v2"
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются, ничего не меняется."
  touch "$PROJ_STATE_FILE"
  : >"$PROJ_STATE_FILE.tmp"

  local i orig decoy cur P D N D2 cfgs vols refs f bname
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"; N="$decoy"
    cur="$(resolve_container "$orig" "$decoy" || true)"
    [ -z "$cur" ] && { c_yel "· $orig/$decoy — нет контейнера, пропуск"; continue; }

    P="$(docker_label "$cur" com.docker.compose.project)"
    D="$(docker_label "$cur" com.docker.compose.project.working_dir)"
    cfgs="$(docker_label "$cur" com.docker.compose.project.config_files)"
    if [ -z "$P" ] || [ -z "$D" ]; then c_yel "· $cur — не из compose, пропуск"; continue; fi
    if [ "$P" = "$N" ]; then c_dim "· $cur: проект уже $N"; continue; fi

    # защита данных: именованные тома → пропуск (так автоматически минуем caddy)
    vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$P" 2>/dev/null || true)"
    if [ -n "$vols" ]; then
      c_yel "· $P: есть именованные тома — пропуск (риск данных): $(echo $vols | tr '\n' ' ')"
      continue
    fi

    D2="$(dirname "$D")/$N"
    if [ -e "$D2" ]; then c_yel "· $D2 уже существует — пропуск"; continue; fi

    # предупреждение о внешних ссылках на каталог (systemd и т.п.)
    refs="$(grep -rslF -- "$D" /etc/systemd 2>/dev/null | head -3 || true)"
    [ -n "$refs" ] && c_yel "  ! на $D ссылаются (проверьте вручную): $(echo $refs)"

    c_grn "· проект $P → $N,  $D → $D2,  сеть ${P}_default → ${N}_default"

    # -f аргументы для старого (D) и нового (D2) расположения
    local -a fold=() fnew=()
    local OLDIFS="$IFS"; IFS=','
    for f in $cfgs; do
      f="$(trim "$f")"; [ -z "$f" ] && continue
      case "$f" in /*) ;; *) f="$D/$f" ;; esac
      fold+=( -f "$f" ); fnew+=( -f "${f/#$D/$D2}" )
    done
    IFS="$OLDIFS"

    # бэкап compose-файлов
    if [ "$DRY_RUN" != 1 ]; then
      for f in "${fold[@]}"; do
        [ "$f" = "-f" ] && continue
        [ -f "$f" ] && { bname="$(echo "$f" | sed 's#/#_#g')"; cp "$f" "$BACKUP_DIR/$bname"; }
      done
    fi

    run docker compose -p "$P" --project-directory "$D" "${fold[@]}" down
    run mv "$D" "$D2"
    if [ "$DRY_RUN" = 1 ]; then
      c_dim "  [dry] sed '$D' → '$D2' в compose-файлах ${fnew[*]}"
    else
      for f in "${fnew[@]}"; do [ "$f" = "-f" ] && continue; replace_path "$f" "$D" "$D2"; done
    fi
    run docker compose -p "$N" --project-directory "$D2" "${fnew[@]}" up -d

    echo "$N|$P|$D2|$D|$cfgs" >>"$PROJ_STATE_FILE.tmp"
  done

  if [ "$DRY_RUN" = 1 ]; then
    rm -f "$PROJ_STATE_FILE.tmp"
    echo; c_yel "Это был dry-run — на сервере ничего не изменилось."
    return
  fi
  cat "$PROJ_STATE_FILE.tmp" >>"$PROJ_STATE_FILE"; rm -f "$PROJ_STATE_FILE.tmp"
  echo
  c_grn "Готово. Проверка:"
  c_dim "  docker ps -a --format 'table {{.Names}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}'"
}

cmd_project_restore() {
  [ -f "$PROJ_STATE_FILE" ] || die "нет состояния проектов ($PROJ_STATE_FILE)"
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются."
  local N P D2 D cfgs f
  while IFS='|' read -r N P D2 D cfgs; do
    [ -z "$N" ] && continue
    local -a fcur=() forig=()
    local OLDIFS="$IFS"; IFS=','
    for f in $cfgs; do
      f="$(trim "$f")"; [ -z "$f" ] && continue
      case "$f" in /*) ;; *) f="$D/$f" ;; esac
      forig+=( -f "$f" ); fcur+=( -f "${f/#$D/$D2}" )
    done
    IFS="$OLDIFS"
    c_grn "· проект $N → $P,  $D2 → $D"
    run docker compose -p "$N" --project-directory "$D2" "${fcur[@]}" down
    run mv "$D2" "$D"
    if [ "$DRY_RUN" != 1 ]; then
      for f in "${forig[@]}"; do [ "$f" = "-f" ] && continue; replace_path "$f" "$D2" "$D"; done
    fi
    run docker compose -p "$P" --project-directory "$D" "${forig[@]}" up -d
  done <"$PROJ_STATE_FILE"
  [ "$DRY_RUN" = 1 ] && { echo; c_yel "Это был dry-run."; return; }
  rm -f "$PROJ_STATE_FILE"
  echo; c_grn "Откат проектов завершён."
}

# Шаг D (ядро): переименовать бинарь ядра (rw-core/xray → netd) производным
# образом. Имя процесса comm и argv перестают выдавать xray/rw-core.
# Остаётся аргумент с сокетом remnawave-internal-*.sock — он не убирается здесь.
cmd_core() {
  load_conf
  local compose; compose="$(compose_cmd)"
  [ -n "$compose" ] || die "нужен docker compose v2"
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются."
  touch "$CORE_STATE_FILE"; : >"$CORE_STATE_FILE.tmp"

  local i orig decoy cur base newtag file svc wd cfgs ctx bname
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"
    cur="$(resolve_container "$orig" "$decoy" || true)"
    [ -z "$cur" ] && continue

    # есть ли ядро в этом контейнере?
    if ! docker exec "$cur" sh -c 'test -e /usr/local/bin/rw-core -o -e /usr/local/bin/xray' >/dev/null 2>&1; then
      continue
    fi
    # уже замаскировано? (бинарь netd на месте) — пропуск, без лишней пересборки
    if docker exec "$cur" sh -c 'test -e /usr/local/bin/netd' >/dev/null 2>&1; then
      c_dim "· $cur: ядро уже замаскировано (netd)"
      continue
    fi

    base="$(docker inspect -f '{{.Config.Image}}' "$cur")"
    case "$base" in *:*) newtag="${base%:*}:core" ;; *) newtag="${base}:core" ;; esac
    file="$(compose_file_of "$cur")"
    svc="$(docker_label "$cur" com.docker.compose.service)"
    wd="$(docker_label "$cur" com.docker.compose.project.working_dir)"
    cfgs="$(docker_label "$cur" com.docker.compose.project.config_files)"

    c_grn "· $cur: ядро rw-core/xray → netd,  образ $base → $newtag"

    if [ "$DRY_RUN" = 1 ]; then
      c_dim "  [dry] docker build -t $newtag (FROM $base + переименование бинаря и обёртка)"
      c_dim "  [dry] image: $base → $newtag в ${file:-?},  пересоздать $svc"
      echo "$newtag|$base|${file:-}|${svc:-}|${wd:-}|${cfgs:-}" >>"$CORE_STATE_FILE.tmp"
      continue
    fi

    ctx="$STATE_DIR/core-build"
    mkdir -p "$ctx"
    cat >"$ctx/rename-core.sh" <<'EOS'
#!/bin/sh
set -eu
if [ -L /usr/local/bin/rw-core ]; then
  real="$(readlink -f /usr/local/bin/rw-core)"
elif [ -f /usr/local/bin/xray ]; then
  real=/usr/local/bin/xray
else
  real=""
fi
if [ -n "$real" ] && [ "$real" != /usr/local/bin/netd ]; then
  mv "$real" /usr/local/bin/netd
  rm -f /usr/local/bin/rw-core
  printf '#!/bin/sh\nexec /usr/local/bin/netd "$@"\n' > /usr/local/bin/rw-core
  chmod +x /usr/local/bin/rw-core
fi
EOS
    cat >"$ctx/Dockerfile" <<'EOS'
ARG BASE
FROM ${BASE}
COPY rename-core.sh /tmp/rename-core.sh
RUN sh /tmp/rename-core.sh && rm -f /tmp/rename-core.sh
EOS
    docker build --build-arg BASE="$base" -t "$newtag" "$ctx"

    if [ -n "$file" ] && [ -f "$file" ]; then
      bname="$(echo "$file" | sed 's#/#_#g')"
      [ -f "$BACKUP_DIR/$bname" ] || cp "$file" "$BACKUP_DIR/$bname"
      replace_image "$file" "$base" "$newtag"
    fi
    compose_up "$svc" "$wd" "$cfgs"
    echo "$newtag|$base|${file:-}|${svc:-}|${wd:-}|${cfgs:-}" >>"$CORE_STATE_FILE.tmp"
  done

  if [ "$DRY_RUN" = 1 ]; then rm -f "$CORE_STATE_FILE.tmp"; echo; c_yel "Это был dry-run."; return; fi
  cat "$CORE_STATE_FILE.tmp" >>"$CORE_STATE_FILE"; rm -f "$CORE_STATE_FILE.tmp"
  echo
  c_grn "Готово. ОБЯЗАТЕЛЬНО проверь:"
  c_dim "  docker top <ядро> -eo pid,comm,args   # comm должен стать netd"
  c_dim "  нода ОНЛАЙН в панели Remnawave (главный тест!)"
  c_yel "Если нода offline или comm снова rw-core — откат: relabel core-restore"
}

cmd_core_restore() {
  [ -f "$CORE_STATE_FILE" ] || die "нет состояния ядра ($CORE_STATE_FILE)"
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются."
  local newtag base file svc wd cfgs
  while IFS='|' read -r newtag base file svc wd cfgs; do
    [ -z "$newtag" ] && continue
    c_grn "· ядро: $newtag → $base"
    if [ "$DRY_RUN" = 1 ]; then
      c_dim "  [dry] image: $newtag → $base в ${file:-?}, пересоздать $svc, удалить $newtag"
      continue
    fi
    if [ -n "$file" ] && [ -f "$file" ] && grep -Eq "image:[[:space:]]*[\"']?${newtag}[\"']?" "$file"; then
      replace_image "$file" "$newtag" "$base"
    fi
    [ -n "$svc" ] && [ -n "$wd" ] && compose_up "$svc" "$wd" "$cfgs" || true
    docker rmi "$newtag" >/dev/null 2>&1 || true
  done <"$CORE_STATE_FILE"
  [ "$DRY_RUN" = 1 ] && { echo; c_yel "Это был dry-run."; return; }
  rm -f "$CORE_STATE_FILE"
  echo; c_grn "Откат ядра завершён."
}

# Шаг C: маскировка host-путей bind-монтирований, чьё имя выдаёт VPN
# (например /var/log/remnanode). Меняется только host-часть; путь внутри
# контейнера остаётся прежним, поэтому приложение не ломается.
cmd_hostpaths() {
  load_conf
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются."
  touch "$HOSTPATH_STATE_FILE"; : >"$HOSTPATH_STATE_FILE.tmp"

  local i orig decoy cur file svc wd cfgs binds src base dec newsrc bname changed
  for i in "${!ORIG_LIST[@]}"; do
    orig="${ORIG_LIST[$i]}"; decoy="${DECOY_LIST[$i]}"
    cur="$(resolve_container "$orig" "$decoy" || true)"
    [ -z "$cur" ] && continue
    file="$(compose_file_of "$cur")"
    svc="$(docker_label "$cur" com.docker.compose.service)"
    wd="$(docker_label "$cur" com.docker.compose.project.working_dir)"
    cfgs="$(docker_label "$cur" com.docker.compose.project.config_files)"

    binds="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$cur" 2>/dev/null || true)"
    changed=0
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      base="$(basename "$src")"
      dec="$(decoy_for "$base" || true)"   # host-путь палевный, только если его имя = исходное имя из карты
      [ -z "$dec" ] && continue
      newsrc="$(dirname "$src")/$dec"
      [ "$src" = "$newsrc" ] && continue
      c_grn "· $cur: host-путь $src → $newsrc (внутри контейнера путь не меняется)"
      if [ "$DRY_RUN" = 1 ]; then
        c_dim "  [dry] mkdir $newsrc; перенос данных; правка bind в ${file:-?}; пересоздать $svc; убрать $src"
        echo "$cur|$src|$newsrc|${file:-}|${svc:-}|${wd:-}|${cfgs:-}" >>"$HOSTPATH_STATE_FILE.tmp"
        continue
      fi
      mkdir -p "$newsrc"
      if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then cp -a "$src/." "$newsrc/" 2>/dev/null || true; fi
      if [ -n "$file" ] && [ -f "$file" ]; then
        bname="$(echo "$file" | sed 's#/#_#g')"
        [ -f "$BACKUP_DIR/$bname" ] || cp "$file" "$BACKUP_DIR/$bname"
        replace_bind_host "$file" "$src" "$newsrc"
      fi
      changed=1
      echo "$cur|$src|$newsrc|${file:-}|${svc:-}|${wd:-}|${cfgs:-}" >>"$HOSTPATH_STATE_FILE.tmp"
      # запомним старый каталог для зачистки после пересоздания
      echo "$src" >>"$HOSTPATH_STATE_FILE.cleanup"
    done <<< "$binds"

    if [ "$changed" = 1 ] && [ "$DRY_RUN" != 1 ]; then
      compose_up "$svc" "$wd" "$cfgs"
    fi
  done

  if [ "$DRY_RUN" = 1 ]; then rm -f "$HOSTPATH_STATE_FILE.tmp"; echo; c_yel "Это был dry-run."; return; fi
  # зачистка опустевших старых каталогов (только если пусты)
  if [ -f "$HOSTPATH_STATE_FILE.cleanup" ]; then
    while IFS= read -r src; do [ -n "$src" ] && rmdir "$src" 2>/dev/null || true; done <"$HOSTPATH_STATE_FILE.cleanup"
    rm -f "$HOSTPATH_STATE_FILE.cleanup"
  fi
  cat "$HOSTPATH_STATE_FILE.tmp" >>"$HOSTPATH_STATE_FILE"; rm -f "$HOSTPATH_STATE_FILE.tmp"
  echo; c_grn "Готово. Проверка: ls /var/log | grep -i remna  (должно быть пусто)"
}

cmd_hostpaths_restore() {
  [ -f "$HOSTPATH_STATE_FILE" ] || die "нет состояния host-путей ($HOSTPATH_STATE_FILE)"
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: команды только показываются."
  local cur oldhost newhost file svc wd cfgs
  while IFS='|' read -r cur oldhost newhost file svc wd cfgs; do
    [ -z "$cur" ] && continue
    c_grn "· $cur: host-путь $newhost → $oldhost"
    if [ "$DRY_RUN" = 1 ]; then c_dim "  [dry] вернуть bind и каталог, пересоздать $svc"; continue; fi
    mkdir -p "$oldhost"
    if [ -d "$newhost" ] && [ -n "$(ls -A "$newhost" 2>/dev/null)" ]; then cp -a "$newhost/." "$oldhost/" 2>/dev/null || true; fi
    if [ -n "$file" ] && [ -f "$file" ]; then replace_bind_host "$file" "$newhost" "$oldhost"; fi
    [ -n "$svc" ] && [ -n "$wd" ] && compose_up "$svc" "$wd" "$cfgs" || true
    rmdir "$newhost" 2>/dev/null || true
  done <"$HOSTPATH_STATE_FILE"
  [ "$DRY_RUN" = 1 ] && { echo; c_yel "Это был dry-run."; return; }
  rm -f "$HOSTPATH_STATE_FILE"
  echo; c_grn "Откат host-путей завершён."
}

# Оркестратор: всё одной командой, в правильном порядке.
cmd_all() {
  c_grn "════ A1: имена контейнеров ════"; cmd_apply
  c_grn "════ A2: образы ════";            cmd_images
  c_grn "════ B: проекты/каталоги/сети ════"; cmd_project
  c_grn "════ D: ядро (rw-core/xray → netd) ════"; cmd_core
  c_grn "════ C: host-пути логов ════";     cmd_hostpaths
  echo
  if [ "$DRY_RUN" = 1 ]; then c_yel "DRY-RUN завершён — на сервере ничего не изменилось."; else
    c_grn "Всё применено. Проверь: docker ps ; нода ОНЛАЙН в панели."
  fi
}

# Установка selfsteal-сайта (маскирующий лендинг Caddy) из форка ASTORKA.
# Идемпотентно: если контейнер уже есть (caddy-selfsteal или web-frontend) — пропуск.
# Интерактивно (installer спросит домен и т.п.) — нужен TTY.
SELFSTEAL_URL="https://github.com/ASTORKA/remnawave-scripts/raw/main/selfsteal.sh"
cmd_selfsteal() {
  load_conf
  if docker container inspect web-frontend >/dev/null 2>&1 \
     || docker container inspect caddy-selfsteal >/dev/null 2>&1; then
    c_dim "· selfsteal уже установлен (контейнер есть) — пропуск"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    c_grn "· установить selfsteal (интерактивно — спросит домен)"
    c_dim "  [dry] bash <(curl -Ls $SELFSTEAL_URL) @ install"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { c_yel "· нет curl — пропускаю selfsteal"; return 0; }
  c_grn "· установка selfsteal (ответь на вопросы инсталлятора: домен и т.д.)…"
  bash <(curl -Ls "$SELFSTEAL_URL") @ install
}

# Установка вендоренного управляющего фреймворка (sysmgr) → /opt/sysmgr + команда sysmgr.
# Неинтерактивно: install копирует код и выходит (TUI запускается потом командой sysmgr).
cmd_sysmgr() {
  local sm="$SCRIPT_DIR/sysmgr/sysmgr.sh"
  if [ ! -f "$sm" ]; then c_yel "· sysmgr не найден ($sm) — пропуск"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    c_grn "· установить sysmgr → /opt/sysmgr, команда 'sysmgr'"
    c_dim "  [dry] bash $sm install"
    return 0
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then c_yel "· sysmgr install требует root — пропуск"; return 0; fi
  c_grn "· установка управляющего фреймворка sysmgr (→ /opt/sysmgr, команда 'sysmgr')…"
  bash "$sm" install
}

# Фильтр VPN-портов mobile443 в режиме block-only (БЕЗ Telegram): дропает IP
# из blocklist'ов (гос-сети + антисканеры). Не запирает на мобильные ASN.
# Вендорен (asn.sh локальный); листы тянутся из traffic-guard-lists (данные).
# install — интерактивный (спросит листы и порты), update — рефреш по конфигу.
cmd_mobile443() {
  local m="$SCRIPT_DIR/mobile443/asn.sh"
  if [ ! -f "$m" ]; then c_yel "· mobile443 не найден ($m) — пропуск"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    if [ -f /opt/mobile443/config.conf ]; then
      c_grn "· mobile443 уже стоит → обновить листы"
      c_dim "  [dry] bash $m update block-only"
    else
      c_grn "· установить mobile443 block-only (дроп gov/antiscanner на портах)"
      c_dim "  [dry] PORTS='${PORTS:-443}' bash $m install block-only"
    fi
    return 0
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then c_yel "· mobile443 требует root — пропуск"; return 0; fi
  if [ -f /opt/mobile443/config.conf ]; then
    c_grn "· mobile443 уже установлен — обновляю blocklist'ы…"
    bash "$m" update block-only
  else
    c_grn "· установка mobile443 block-only (ответь: какие листы и порты)…"
    bash "$m" install block-only
  fi
}

# Маскировка + ускорение/защита ноды (accelerator) одной командой. Нужен root.
# Порты firewall: protect спросит интерактивно, либо задайте через ENV
# (TCP_PORTS/UDP_PORTS/SSH_PORT/WHITELIST + NONINTERACTIVE=1) ДО запуска.
cmd_all_with_accel() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    c_yel "ВНИМАНИЕ: selfsteal/optimize/protect требуют root — запусти через sudo, иначе они пропустятся."
  fi
  echo; c_grn "════ selfsteal (маскирующий сайт) ════"; cmd_selfsteal
  cmd_all
  local acc="$SCRIPT_DIR/accelerator/install.sh"
  if [ ! -f "$acc" ]; then
    c_yel "accelerator не найден ($acc) — ускорение/защита пропущены"
    return
  fi
  echo; c_grn "════ ускорение ноды (accelerator → optimize) ════"
  run bash "$acc" optimize
  echo; c_grn "════ защита ноды (accelerator → protect) ════"
  run bash "$acc" protect
  echo; c_grn "════ фильтр портов (mobile443 block-only) ════"; cmd_mobile443
  echo; c_grn "════ диагностика (read-only) ════"
  run bash "$acc" diagnose
  echo; c_grn "════ управляющий фреймворк (sysmgr) ════"; cmd_sysmgr
  echo
  if [ "$DRY_RUN" = 1 ]; then c_yel "DRY-RUN завершён — на сервере ничего не изменилось."; else
    c_grn "Готово: selfsteal + маскировка + ускорение + защита + mobile443 + sysmgr."
    c_yel "Если optimize ставил XanMod — нужен reboot (uname -r должен содержать xanmod)."
    c_dim "Управление: команда 'sysmgr' (TUI)."
  fi
}

# Полный откат в обратном порядке (пути синхронизируются по шагам).
cmd_all_restore() {
  c_grn "════ откат ядра ════";    [ -f "$CORE_STATE_FILE" ] && cmd_core_restore || c_dim "· ядро не маскировалось"
  c_grn "════ откат проектов ════"; [ -f "$PROJ_STATE_FILE" ] && cmd_project_restore || c_dim "· проекты не менялись"
  c_grn "════ откат образов ════";  [ -f "$IMG_STATE_FILE" ] && cmd_images_restore || c_dim "· образы не менялись"
  c_grn "════ откат host-путей ════"; [ -f "$HOSTPATH_STATE_FILE" ] && cmd_hostpaths_restore || c_dim "· host-пути не менялись"
  c_grn "════ откат имён контейнеров ════"; [ -f "$STATE_FILE" ] && cmd_restore || c_dim "· имена не менялись"
  echo
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN завершён." || c_grn "Полный откат завершён."
}

# Полное удаление: откат ВСЕХ действий (сервисы + маскировка) и снятие команды.
# Порядок обратный установке. selfsteal-сайт и каталог репо НЕ трогаем (см. вывод).
cmd_uninstall() {
  [ "$DRY_RUN" = 1 ] && c_yel "DRY-RUN: показываю шаги удаления, ничего не меняю."
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    c_yel "ВНИМАНИЕ: удаление сервисов (firewall/тюнинг/mobile443/sysmgr) требует root — без него они пропустятся."
  fi

  echo; c_grn "════ удаление mobile443 (фильтр портов) ════"
  if [ -d /opt/mobile443 ] && [ -f "$SCRIPT_DIR/mobile443/asn.sh" ]; then
    run bash "$SCRIPT_DIR/mobile443/asn.sh" remove block-only
  else c_dim "· mobile443 не установлен — пропуск"; fi

  echo; c_grn "════ откат accelerator (firewall + тюнинг) ════"
  if [ -f "$SCRIPT_DIR/accelerator/install.sh" ]; then
    run bash "$SCRIPT_DIR/accelerator/install.sh" rollback all
  else c_dim "· accelerator нет — пропуск"; fi

  echo; c_grn "════ удаление sysmgr (управляющий фреймворк) ════"
  if [ -d /opt/sysmgr ]; then
    run rm -rf /opt/sysmgr
    run rm -f /usr/local/bin/sysmgr /var/log/sysmgr.log
    if [ "$DRY_RUN" = 1 ]; then
      c_dim "  [dry] снять alias sysmgr из ~/.bashrc, удалить ~/.sysmgr_fleet"
    else
      sed -i '/alias sysmgr=/d' /root/.bashrc 2>/dev/null || true
      rm -f "$HOME/.sysmgr_fleet" /root/.sysmgr_fleet 2>/dev/null || true
    fi
    c_grn "· sysmgr удалён (/opt/sysmgr, команда, лог, база флота)"
    c_dim "  (модули, включённые вручную из TUI — geoblock/shaper — снимай заранее в самом sysmgr)"
  else c_dim "· sysmgr не установлен — пропуск"; fi

  echo; c_grn "════ размаскировка ноды (restore-all) ════"
  cmd_all_restore

  echo; c_grn "════ снятие команды relabel ════"
  run rm -f /usr/local/bin/relabel

  echo
  if [ "$DRY_RUN" = 1 ]; then c_yel "Это был dry-run — ничего не удалено."; return; fi
  c_grn "Удаление завершено."
  c_yel "Осталось вручную (по желанию):"
  c_dim "  • selfsteal-сайт (контейнер caddy-selfsteal) — снять его инсталлятором, не трогали"
  c_dim "  • каталог репозитория:  rm -rf $SCRIPT_DIR"
}

usage() {
  cat <<'EOF'
relabel.sh — маскировка имён docker-контейнеров VPN-ноды

ОДНОЙ КОМАНДОЙ:
  relabel all [--dry-run]      применить ВСЁ маскирование (A→B→C→D)
  relabel all-with-accelerator [--dry-run]  selfsteal+маскирование+optimize+protect+mobile443+sysmgr (root!)
  relabel restore-all [--dry-run]  откатить ВСЁ маскирование
  relabel uninstall [--dry-run]    ПОЛНОЕ удаление: откат всего + снять сервисы и команду

ПО ШАГАМ:
  relabel status               показать текущее состояние маскировки
  relabel apply  [--dry-run]   A1: имена контейнеров (из names.conf)
  relabel images [--dry-run]   A2: имена образов (ретег + пересоздание)
  relabel project [--dry-run]  B:  проект + каталог + сеть compose
  relabel hostpaths [--dry-run] C: host-пути логов (/var/log/remnanode → …)
  relabel core   [--dry-run]   D:  имя процесса ядра (rw-core/xray → netd)
  relabel selfsteal [--dry-run] установить selfsteal-сайт (если ещё не стоит)
  relabel sysmgr [--dry-run]   установить управляющий фреймворк sysmgr (root)
  relabel mobile443 [--dry-run] фильтр портов: дроп blocklist'ов, block-only (root)
  relabel ps                   показать процессы внутри контейнеров

ОТКАТ ПО ШАГАМ:  restore / images-restore / project-restore /
                 hostpaths-restore / core-restore   (все принимают --dry-run)

Совет: всегда сначала `relabel all --dry-run` — покажет все команды,
ничего не меняя. `all` делает down+up (короткий простой ноды).
Проекты с именованными томами пропускаются автоматически (защита данных).
Карта имён — в names.conf. Бэкапы и карты отката — в .state/.
EOF
}

# --- точка входа ------------------------------------------------------------

need_docker
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
case "${1:-}" in
  status)            cmd_status ;;
  all)               cmd_all ;;
  all-with-accelerator) cmd_all_with_accel ;;
  restore-all)       cmd_all_restore ;;
  uninstall|purge)   cmd_uninstall ;;
  apply)             cmd_apply ;;
  restore)           cmd_restore ;;
  images)            cmd_images ;;
  images-restore)    cmd_images_restore ;;
  project)           cmd_project ;;
  project-restore)   cmd_project_restore ;;
  hostpaths)         cmd_hostpaths ;;
  hostpaths-restore) cmd_hostpaths_restore ;;
  core)              cmd_core ;;
  core-restore)      cmd_core_restore ;;
  selfsteal)         cmd_selfsteal ;;
  sysmgr)            cmd_sysmgr ;;
  mobile443)         cmd_mobile443 ;;
  ps)                cmd_ps ;;
  ""|-h|--help|help) usage ;;
  *) die "неизвестная команда: $1 (см. --help)" ;;
esac
