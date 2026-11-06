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
NO_MASK=0   # 1 — ставить сервисы, но НЕ переименовывать (для all-with-accelerator)
NO_SELFSTEAL=0  # 1 — не ставить selfsteal-заглушку (для all-with-accelerator)
NO_BLOCK=0  # 1 — НЕ ставить блокировщики трафика: protect (firewall) и mobile443
NO_ANTISCAN=0  # 1 — firewall ставить, но без антисканеров на сервисных портах:
               #     без mobile443, portscan-автобана и CrowdSec

# Прокси-префикс для обхода DPI-блокировок GitHub (raw/api/codeload/git clone).
# По умолчанию https://gh-proxy.com/ ; переопределяется через ENV; пусто = напрямую.
# Экспортируем, чтобы дочерние скрипты (accelerator, mobile443) унаследовали значение.
GH_PROXY="${GH_PROXY:-https://gh-proxy.com/}"
export GH_PROXY

# Завернуть один github-URL через прокси (пусто GH_PROXY → URL без изменений).
gh_url() { printf '%s%s' "$GH_PROXY" "$1"; }

# Переписать github-URL'ы внутри файла на прокси (для скачанных чужих скриптов).
gh_rewrite_file() {
  [ -n "$GH_PROXY" ] || return 0
  sed -i -E "s#https://(raw\.githubusercontent\.com|github\.com|api\.github\.com|codeload\.github\.com|objects\.githubusercontent\.com)#${GH_PROXY}https://\1#g" "$1"
}

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

# Гарантировать РОВНО ОДНУ строку container_name со значением $to.
# Чинит и дубликаты (оставляет первую, остальные удаляет) — идемпотентно.
# Расчёт на single-service node-compose (по одному сервису на файл).
ensure_container_name() {
  local file="$1" to="$2" tmp
  tmp="$(mktemp)"
  awk -v to="$to" '
    /^[[:space:]]*container_name:/ {
      if (!seen) { match($0, /^[[:space:]]*/); print substr($0,1,RLENGTH) "container_name: " to; seen=1 }
      next
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

      if grep -Eq "^[[:space:]]*container_name:" "$file"; then
        # есть container_name (любое значение, возможны дубликаты) → нормализуем к decoy
        ensure_container_name "$file" "$decoy"
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
#
# selfsteal.sh ВЕНДОРЕН в репозиторий (selfsteal/selfsteal.sh) — по умолчанию
# берём локальную копию, БЕЗ обращения к GitHub (иначе на DPI-сетях скачивание
# зависает). Если локальной копии нет — скачиваем с таймаутами (не виснем вечно).
# В обоих случаях внутренние github-ссылки скрипта переписываются на GH_PROXY
# (он сам тянет шаблоны/acme.sh/api с github).
SELFSTEAL_LOCAL="$SCRIPT_DIR/selfsteal/selfsteal.sh"
SELFSTEAL_URL="$(gh_url "https://github.com/ASTORKA/remnawave-scripts/raw/main/selfsteal.sh")"
cmd_selfsteal() {
  load_conf
  if docker container inspect web-frontend >/dev/null 2>&1 \
     || docker container inspect caddy-selfsteal >/dev/null 2>&1 \
     || docker container inspect nginx-selfsteal >/dev/null 2>&1; then
    c_dim "· selfsteal уже установлен (контейнер есть) — пропуск"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$OPT_DOMAINS" ]; then c_grn "· установить selfsteal без вопросов: домен $(split_list "$OPT_DOMAINS" | head -1) (--force --domain)"
    else c_grn "· установить selfsteal (интерактивно — спросит домен)"; fi
    if [ -f "$SELFSTEAL_LOCAL" ]; then c_dim "  [dry] bash <(gh_rewrite $SELFSTEAL_LOCAL) @ install  (локальная копия)"
    else c_dim "  [dry] curl $SELFSTEAL_URL → rewrite → bash @ install"; fi
    return 0
  fi
  local _sf; _sf="$(mktemp)"
  if [ -f "$SELFSTEAL_LOCAL" ]; then
    c_grn "· установка selfsteal из локальной копии (ответь на вопросы: домен и т.д.)…"
    cp "$SELFSTEAL_LOCAL" "$_sf"
  else
    command -v curl >/dev/null 2>&1 || { c_yel "· нет curl — пропускаю selfsteal"; rm -f "$_sf"; return 0; }
    c_grn "· скачиваю selfsteal ($SELFSTEAL_URL)…"
    if ! curl -fL --connect-timeout 20 --max-time 120 --retry 2 "$SELFSTEAL_URL" -o "$_sf" || [ ! -s "$_sf" ]; then
      c_yel "· не удалось скачать selfsteal — пропуск (сеть/DPI). Проверь GH_PROXY."; rm -f "$_sf"; return 0
    fi
  fi
  # Переписываем ВНУТРЕННИЕ github-URL'ы скрипта на прокси (обход DPI).
  gh_rewrite_file "$_sf"
  # шаблоны заглушки тоже вендорены — selfsteal возьмёт их без сети
  # Домены заданы (--domains / DOMAINS=) — ставим без вопросов: первый домен основной,
  # остальные добавит relabel domains следом. DNS проверяем сами (force его пропускает).
  local _first; _first="$(split_list "$OPT_DOMAINS" | head -1)"
  if [ -n "$_first" ]; then
    valid_domain "$_first" || { rm -f "$_sf"; die "не похоже на домен: $_first"; }
    domains_dns_check "$_first"
    c_grn "· selfsteal без вопросов: домен $_first, случайный шаблон"
    SELFSTEAL_TEMPLATES_DIR="$SCRIPT_DIR/selfsteal/sni-templates" bash "$_sf" @ --force --domain "$_first" install
  else
    SELFSTEAL_TEMPLATES_DIR="$SCRIPT_DIR/selfsteal/sni-templates" bash "$_sf" @ install
  fi
  rm -f "$_sf"
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

# Хост «IP в SNI + фрагментация» (Reality без SNI): заглушка selfsteal должна
# отдавать сертификат своего домена на ClientHello без имени. Новые установки
# selfsteal уже такие; на старых дописываем default_sni в Caddyfile.
# Затем проверка через 443 (Xray → Reality → заглушка) и подсказка для панели.
# default_sni после auto_https + сайт вместо `respond 204` в блоке :{$SELF_STEAL_PORT}.
patch_caddyfile_ipsni() {
  local f="$1" tmp
  tmp="$(mktemp)"
  awk '
    { ind = $0; sub(/[^ \t].*$/, "", ind) }
    /^:\{\$SELF_STEAL_PORT\} \{/ { inblk = 1 }
    inblk && /^\}/ { inblk = 0 }
    inblk && $1 == "respond" && $2 == "204" && NF == 2 {
      print ind "root * /var/www/html"; print ind "try_files {path} /index.html"; print ind "file_server"; next
    }
    { print }
    $1 == "auto_https" && $2 == "disable_redirects" { print ind "default_sni {$SELF_STEAL_DOMAIN}" }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

cmd_ipsni() {
  local c="" n
  for n in web-frontend caddy-selfsteal nginx-selfsteal; do
    docker container inspect "$n" >/dev/null 2>&1 && { c="$n"; break; }
  done
  [ -n "$c" ] || die "заглушка selfsteal не найдена — сначала: relabel selfsteal"
  local cf
  cf="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$c")"
  if [ -n "$cf" ] && [ -f "$cf" ]; then
    if grep -q 'default_sni' "$cf"; then
      c_dim "· Caddyfile ($cf): default_sni уже есть"
    else
      c_grn "· Caddyfile ($cf): + default_sni, сайт вместо 204 в catch-all"
      run mkdir -p "$BACKUP_DIR"
      run cp -a "$cf" "$BACKUP_DIR/Caddyfile.$(date +%s)"
      run patch_caddyfile_ipsni "$cf"
      run docker restart "$c"
      [ "$DRY_RUN" = 1 ] || sleep 3
    fi
  else
    c_dim "· $c — nginx на unix-сокете: единственный server, без SNI и так отдаёт свой сертификат"
  fi
  [ "$DRY_RUN" = 1 ] && return 0

  # Не 127.0.0.1: заглушка может слушать 127.0.0.1:443 сама, и проверка прошла бы
  # мимо Xray. Внешний адрес ноды попадает в *:443 — то есть в Reality, как у пробника.
  local lip
  lip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  [ -n "$lip" ] || die "не определил внешний IPv4 ноды (ip route get)"
  echo; c_grn "════ проверка: TLS на $lip:443 без SNI (как увидит пробник) ════"
  local out subj vr code
  out="$(timeout 10 openssl s_client -connect "$lip:443" -noservername </dev/null 2>&1 || true)"
  subj="$(printf '%s\n' "$out" | grep -m1 '^subject=' || true)"
  vr="$(printf '%s\n' "$out" | grep -m1 'Verify return code' || true)"
  code="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$lip/" || true)"
  echo "  сертификат: ${subj:-нет ответа}"
  echo "  ${vr:-Verify: нет ответа}"
  echo "  HTTP по IP: ${code:-нет ответа}"
  if printf '%s' "$vr" | grep -q ': 0 (ok)' && [ "$code" = 200 ]; then
    c_grn "  OK — без SNI отдаётся сайт с валидным сертификатом"
  else
    c_yel "  Не то: ожидался сертификат домена (Verify 0) и HTTP 200. Проверь target у Reality-инбаунда на 443 и docker logs $c"
  fi

  local ip; ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo IP_НОДЫ)"
  cat <<IPSNI_EOF

════ что сделать в панели Remnawave ════
1) Профиль конфига, Reality-инбаунд на 443:
     serverNames: ["<твой домен>", ""]   — пустая строка ВТОРОЙ: без неё клиент без SNI уйдёт в заглушку
     shortIds: первым настоящий shortId (не "")
     target: заглушка selfsteal (как сейчас; 127.0.0.1:443 — нормально, если там она), не чужой сайт
2) Новый хост на этот инбаунд:
     Address: $ip   Port: 443   SNI: $ip   Fingerprint: firefox   ALPN: пусто
     Final Mask: {"tcp":[{"type":"fragment","settings":{"lengths":["10-20"],"delays":["0"],"packets":"tlshello"}}]}
3) Хост — в нужный сквад. Клиенту нужна Xray JSON-подписка (sing-box/Mihomo маску не получат).
IPSNI_EOF
}

# Блокировка подсетей сканеров на весь сервер (ipset + iptables): гос-сети,
# антисканеры, skipa + свои списки, статистика, меню `ipfilter`, ежедневное
# обновление листов. Вендорен из Flecksis/rkn-guard (MIT) под нейтральным
# именем sys-ipfilter; бинарник собран из исходников в ipfilter/bin/, листы —
# через GH_PROXY. Выключенный UFW НЕ включает (порты ноды не закроются).
# В all-with-accelerator не входит (пересекается с mobile443) — ставится отдельно.
cmd_ipfilter() {
  local m="$SCRIPT_DIR/ipfilter/install.sh"
  if [ ! -f "$m" ]; then c_yel "· ipfilter не найден ($m) — пропуск"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    if command -v sys-ipfilter >/dev/null 2>&1; then
      c_grn "· sys-ipfilter уже стоит → обновить листы"; c_dim "  [dry] bash $m update"
    else
      c_grn "· установить sys-ipfilter (ipset+iptables, листы gov/antiscanner/skipa)"; c_dim "  [dry] IPF_SCHEDULE=${IPF_SCHEDULE:-y} bash $m install"
    fi
    return 0
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then c_yel "· ipfilter требует root — пропуск"; return 0; fi
  if command -v sys-ipfilter >/dev/null 2>&1; then
    c_grn "· sys-ipfilter уже установлен — обновляю листы…"
    bash "$m" update
  else
    c_grn "· установка sys-ipfilter (листы обновляются ежедневно в 06:00; IPF_SCHEDULE=n — без расписания)…"
    IPF_SCHEDULE="${IPF_SCHEDULE:-y}" bash "$m" install
  fi
}

# Маскировка + ускорение/защита ноды (accelerator) одной командой. Нужен root.
# Порты firewall: protect спросит интерактивно, либо задайте через ENV
# (TCP_PORTS/UDP_PORTS/SSH_PORT/WHITELIST + NONINTERACTIVE=1) ДО запуска.
cmd_all_with_accel() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    c_yel "ВНИМАНИЕ: selfsteal/optimize/protect требуют root — запусти через sudo, иначе они пропустятся."
  fi
  # Адреса — первыми: домены заглушки должны указывать на уже повешенные IP,
  # иначе Let's Encrypt не достучится и сертификат не выпустится.
  if [ -n "$OPT_IN" ] || [ -n "$OPT_OUT" ]; then
    echo; c_grn "════ входные/выходные адреса (relabel ips) ════"; cmd_ips
  fi
  if [ "$NO_SELFSTEAL" = 1 ]; then
    echo; c_yel "════ selfsteal ПРОПУЩЕН (--no-selfsteal): заглушку не ставлю ════"
  else
    echo; c_grn "════ selfsteal (маскирующий сайт) ════"; cmd_selfsteal
  fi
  if [ -n "$OPT_DOMAINS" ]; then
    echo; c_grn "════ домены заглушки (relabel domains) ════"; cmd_domains
  fi
  if [ "$NO_MASK" = 1 ]; then
    echo; c_yel "════ маскировка ПРОПУЩЕНА (--no-mask): ничего не переименовываю ════"
  else
    cmd_all
  fi
  local acc="$SCRIPT_DIR/accelerator/install.sh"
  if [ ! -f "$acc" ]; then
    c_yel "accelerator не найден ($acc) — ускорение/защита пропущены"
    return
  fi
  echo; c_grn "════ ускорение ноды (accelerator → optimize) ════"
  run bash "$acc" optimize
  if [ "$NO_BLOCK" = 1 ]; then
    echo; c_yel "════ блокировщики ПРОПУЩЕНЫ (--no-block): protect и mobile443 не ставлю ════"
  else
    echo; c_grn "════ защита ноды (accelerator → protect) ════"
    if [ "$NO_ANTISCAN" = 1 ]; then
      # Автобан и CrowdSec режут IP целиком, в т.ч. на 443 — выключаем вместе с mobile443.
      c_yel "  --no-antiscan: без portscan-автобана и CrowdSec"
      ENABLE_PORTSCAN_BAN=0 ENABLE_CROWDSEC=0 run bash "$acc" protect
      echo; c_yel "════ mobile443 ПРОПУЩЕН (--no-antiscan): антисканеры на порты не вешаю ════"
    else
      run bash "$acc" protect
      echo; c_grn "════ фильтр портов (mobile443 block-only) ════"; cmd_mobile443
    fi
  fi
  echo; c_grn "════ диагностика (read-only) ════"
  run bash "$acc" diagnose
  echo; c_grn "════ управляющий фреймворк (sysmgr) ════"; cmd_sysmgr
  echo
  if [ "$DRY_RUN" = 1 ]; then c_yel "DRY-RUN завершён — на сервере ничего не изменилось."; else
    local _ss _mask _block
    [ "$NO_SELFSTEAL" = 1 ] && _ss="" || _ss="selfsteal + "
    [ "$NO_MASK" = 1 ] && _mask="" || _mask="маскировка + "
    if [ "$NO_BLOCK" = 1 ]; then _block=""
    elif [ "$NO_ANTISCAN" = 1 ]; then _block="защита (без антисканеров) + "
    else _block="защита + mobile443 + "; fi
    c_grn "Готово: ${_ss}${_mask}ускорение + ${_block}sysmgr."
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

# --- несколько доменов у заглушки + входные/выходные IP ----------------------
#
# relabel domains d1 [d2 ...]   — заглушка selfsteal (Caddy) обслуживает сразу все
#   домены: на каждый свой сертификат (Let's Encrypt по HTTP-01 на :80), редирект
#   http→https, тот же сайт. Первый домен — основной (default_sni для «IP в SNI»).
#   Список хранится в .env (SELF_STEAL_DOMAINS + готовые адреса сайтов); Caddy
#   подставляет {$VAR} до разбора Caddyfile, так что адресов может быть сколько угодно.
#
# relabel ips --in A1,A2 --out B [--ports 443,8443]
#   --in   адреса, на которые подключаются пользователи: VPN-порты (--ports) отвечают
#          ТОЛЬКО на них, на остальных IP сервера дропаются (засвеченный/забаненный IP
#          перестаёт быть VPN). Порт панели (2222) и SSH не трогаются.
#   --out  адрес, с которого нода ходит в интернет (его видят сайты): SNAT новых
#          исходящих соединений с адресов сервера на B. В панели ничего менять не нужно
#          (аналог sendThrough в outbound «DIRECT»).
#   Недостающие адреса из --in/--out вешаются на внешний интерфейс (/32).
#   Всё переживает перезагрузку (systemd-юнит relabel-ips), откат: relabel ips-restore.

IPS_DIR="/etc/relabel-ips"
IPS_UNIT="/etc/systemd/system/relabel-ips.service"
IPS_STATE_FILE="$STATE_DIR/ips.added"   # адреса, которые повесили мы (снимем при откате)

# Значения флагов вида --x a,b или --x=a,b (заполняются в точке входа).
OPT_DOMAINS=""; OPT_IN=""; OPT_OUT=""; OPT_PORTS=""

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.; for o in $ip; do [ "$o" -le 255 ] || return 1; done
}
valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; }

# Список через запятые/пробелы → по строке.
split_list() { printf '%s\n' "$*" | tr ', ' '\n\n' | sed '/^$/d'; }

host_ipv4s() { ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'; }
default_iface() { ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'; }

resolve_a() {
  if command -v dig >/dev/null 2>&1; then dig +short A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$'
  else getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; fi
}

# Найти Caddy-заглушку: имя контейнера, каталог compose, Caddyfile, .env.
find_caddy_selfsteal() {
  SS_C=""; local n
  for n in web-frontend caddy-selfsteal; do
    docker container inspect "$n" >/dev/null 2>&1 && { SS_C="$n"; break; }
  done
  [ -n "$SS_C" ] || return 1
  SS_CF="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$SS_C")"
  SS_WD="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$SS_C" 2>/dev/null || true)"
  SS_CFGS="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$SS_C" 2>/dev/null || true)"
  SS_SVC="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$SS_C" 2>/dev/null || true)"
  [ -n "$SS_CF" ] && [ -f "$SS_CF" ] || return 1
  SS_ENV="$(dirname "$SS_CF")/.env"
  [ -f "$SS_ENV" ] || SS_ENV="$SS_WD/.env"
  [ -f "$SS_ENV" ]
}

# Один раз переводим Caddyfile на адреса из .env (идемпотентно).
patch_caddyfile_domains() {
  local f="$1" tmp
  tmp="$(mktemp)"
  awk '
    $0 ~ /^http:\/\/\{\$SELF_STEAL_DOMAIN\} \{/  { print "{$SELF_STEAL_SITES_HTTP} {"; next }
    $0 ~ /^https:\/\/\{\$SELF_STEAL_DOMAIN\} \{/ { print "{$SELF_STEAL_SITES_HTTPS} {"; next }
    $1 == "redir" && $2 ~ /^https:\/\/\{\$SELF_STEAL_DOMAIN\}/ {
      ind = $0; sub(/[^ \t].*$/, "", ind); print ind "redir https://{host}{uri} permanent"; next
    }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Записать/заменить KEY=VALUE в .env.
env_set() {
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  grep -v "^${k}=" "$f" > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}

# Домены должны резолвиться в адреса этого сервера (с учётом ещё не повешенных --in/--out).
domains_dns_check() {
  echo; c_grn "════ DNS: домены должны указывать на этот сервер ════"
  local mine bad=0 a ok d x
  mine="$(host_ipv4s; split_list "$OPT_IN"; split_list "$OPT_OUT")"
  for d in "$@"; do
    a="$(resolve_a "$d" | tr '\n' ' ' || true)"; ok=0
    for x in $a; do printf '%s\n' "$mine" | grep -qx "$x" && ok=1; done
    if [ "$ok" = 1 ]; then echo "  $d → ${a% }  ✓"
    else c_yel "  $d → ${a:-нет A-записи}  ✗ (не адрес этого сервера — сертификат не выпустится)"; bad=1; fi
  done
  [ "$bad" = 0 ] || [ "${FORCE:-0}" = 1 ] || die "исправь DNS (или FORCE=1, если A-записи ещё расходятся)"
}

cmd_domains() {
  local list=() d
  while IFS= read -r d; do [ -n "$d" ] && list+=("$(printf '%s' "$d" | tr 'A-Z' 'a-z')"); done < <(split_list "$OPT_DOMAINS")
  [ "${#list[@]}" -gt 0 ] || die "укажи домены: relabel domains d1.example.com d2.example.org …"
  for d in "${list[@]}"; do valid_domain "$d" || die "не похоже на домен: $d"; done
  if ! find_caddy_selfsteal; then
    if [ "$DRY_RUN" = 1 ]; then
      c_dim "  [dry] заглушки ещё нет — после установки: домены ${list[*]} в Caddyfile/.env, пересоздание, проверка сертификатов"
      return 0
    fi
    die "Caddy-заглушка selfsteal не найдена (nginx-вариант не поддерживается) — сначала: relabel selfsteal"
  fi
  [ "${EUID:-$(id -u)}" -eq 0 ] || c_yel "ВНИМАНИЕ: без root правка Caddyfile/.env может не пройти."

  domains_dns_check "${list[@]}"

  local http="" https="" main="${list[0]}"
  for d in "${list[@]}"; do http="${http:+$http, }http://$d"; https="${https:+$https, }https://$d"; done
  if grep -q '/etc/caddy/ssl/fullchain.crt' "$SS_CF"; then
    c_yel "· заглушка на ручном сертификате (ssl/fullchain.crt) — он должен покрывать ВСЕ домены (wildcard/SAN)"
  fi

  c_grn "· Caddyfile ($SS_CF) и .env: домены ${list[*]}"
  run mkdir -p "$BACKUP_DIR"
  local ts; ts="$(date +%s)"
  run cp -a "$SS_CF" "$BACKUP_DIR/Caddyfile.$ts"
  run cp -a "$SS_ENV" "$BACKUP_DIR/selfsteal.env.$ts"
  run patch_caddyfile_domains "$SS_CF"
  run env_set "$SS_ENV" SELF_STEAL_DOMAIN "$main"
  run env_set "$SS_ENV" SELF_STEAL_DOMAINS "$(IFS=,; echo "${list[*]}")"
  run env_set "$SS_ENV" SELF_STEAL_SITES_HTTP "$http"
  run env_set "$SS_ENV" SELF_STEAL_SITES_HTTPS "$https"
  [ "$DRY_RUN" = 1 ] && { c_dim "  [dry] пересоздать $SS_C (env_file перечитывается только при up)"; return 0; }

  # env_file читается при создании контейнера → нужен up (restart не подхватит .env).
  if [ -n "$SS_WD" ] && [ -n "$SS_SVC" ] && [ -n "$SS_CFGS" ]; then
    compose_up "$SS_SVC" "$SS_WD" "$SS_CFGS"
  else
    die "не нашёл compose-метки у $SS_C — пересоздай заглушку вручную: cd <каталог> && docker compose up -d"
  fi

  echo; c_grn "════ проверка: сертификаты через 443 (Reality → заглушка) ════"
  local lip t subj left=("${list[@]}")
  lip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  for t in $(seq 1 18); do      # Caddy выпускает сертификаты в фоне — ждём до ~90 с
    local rest=()
    for d in "${left[@]}"; do
      subj="$(timeout 8 openssl s_client -connect "${lip:-127.0.0.1}:443" -servername "$d" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ' || true)"
      if printf '%s' "$subj" | grep -q "CN *= *$d"; then echo "  $d  ✓  ${subj#*notAfter=}"; else rest+=("$d"); fi
    done
    left=("${rest[@]}"); [ "${#left[@]}" -eq 0 ] && break
    sleep 5
  done
  for d in "${left[@]}"; do
    c_yel "  $d  ✗ сертификата нет: проверь, что :80 открыт снаружи и A-запись верна; docker logs $SS_C | grep -i acme"
  done

  cat <<DOM_EOF

════ что сделать в панели Remnawave ════
1) Профиль конфига, Reality-инбаунд на 443 — serverNames (target не трогать):
     $(printf '"%s", ' "${list[@]}" | sed 's/, $//')
   (если используешь хост «IP в SNI» — оставь и "" последним)
2) На каждый домен — свой хост на этот инбаунд:
DOM_EOF
  for d in "${list[@]}"; do echo "     Address: $d   Port: 443   SNI: $d"; done
  echo
}

# Сгенерировать /etc/relabel-ips/{ips.nft,apply.sh} и юнит; применить.
cmd_ips() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || [ "$DRY_RUN" = 1 ] || die "relabel ips требует root"
  command -v nft >/dev/null 2>&1 || [ "$DRY_RUN" = 1 ] || die "нужен nftables (apt install nftables)"
  local ins=() outs=() ports=() x
  while IFS= read -r x; do [ -n "$x" ] && ins+=("$x"); done < <(split_list "$OPT_IN")
  while IFS= read -r x; do [ -n "$x" ] && outs+=("$x"); done < <(split_list "$OPT_OUT")
  while IFS= read -r x; do [ -n "$x" ] && ports+=("$x"); done < <(split_list "${OPT_PORTS:-443}")
  [ "${#ins[@]}" -gt 0 ] || [ "${#outs[@]}" -gt 0 ] || die "укажи --in A1,A2 и/или --out B (см. relabel --help)"
  [ "${#outs[@]}" -le 1 ] || die "--out — один адрес"
  for x in "${ins[@]}" "${outs[@]}"; do valid_ipv4 "$x" || die "не IPv4: $x"; done
  for x in "${ports[@]}"; do [[ "$x" =~ ^[0-9]{1,5}(-[0-9]{1,5})?$ ]] || die "не порт: $x"; done
  for x in "${ports[@]}"; do [ "$x" != 22 ] || die "порт 22 в --ports нельзя — потеряешь SSH"; done

  local ifc; ifc="$(default_iface)"
  [ -n "$ifc" ] || die "не определил внешний интерфейс (нет default route)"
  local mine; mine="$(host_ipv4s)"

  echo; c_grn "════ адреса на $ifc ════"
  local add=()
  for x in "${ins[@]}" "${outs[@]}"; do
    if printf '%s\n' "$mine" | grep -qx "$x"; then echo "  $x  уже на сервере"
    else echo "  $x  + повешу /32"; add+=("$x"); fi
  done

  local out="${outs[0]:-}" pl inl
  pl="$(IFS=,; echo "${ports[*]}" | sed 's/,/, /g')"
  inl="$(IFS=,; echo "${ins[*]}" | sed 's/,/, /g')"

  # источники для SNAT: все адреса сервера, кроме выходного
  local srcs=""
  [ -n "$out" ] && srcs="$(printf '%s\n' $mine "${add[@]}" | sed '/^$/d' | sort -u | grep -vx "$out" | paste -sd, - | sed 's/,/, /g' || true)"
  local nft; nft="$(mktemp)"
  {
    echo "#!/usr/sbin/nft -f"
    echo "# relabel ips — вход: ${ins[*]:-любой}; выход: ${out:-как есть}; VPN-порты: ${ports[*]}"
    echo "table inet relabel_ips {}"
    echo "delete table inet relabel_ips"
    echo "table inet relabel_ips {"
    if [ "${#ins[@]}" -gt 0 ]; then
      echo "  chain input {"
      echo "    type filter hook input priority -5; policy accept;"
      echo "    # VPN-порты отвечают только на входных адресах; loopback (заглушка) не трогаем"
      echo "    ip daddr != { $inl, 127.0.0.0/8 } tcp dport { $pl } drop"
      echo "    ip daddr != { $inl, 127.0.0.0/8 } udp dport { $pl } drop"
      echo "  }"
    fi
    if [ -n "$out" ]; then
      echo "  chain postrouting {"
      echo "    type nat hook postrouting priority srcnat + 5; policy accept;"
      echo "    # новые исходящие с адресов сервера → выходной адрес (ответы на входящие не трогаются)"
      [ -n "$srcs" ] && echo "    oifname \"$ifc\" ip saddr { $srcs } snat ip to $out"
      echo "  }"
    fi
    echo "}"
  } > "$nft"

  if [ "$DRY_RUN" = 1 ]; then
    c_dim "  [dry] ip addr add <адрес>/32 dev $ifc  для: ${add[*]:-—}"
    c_dim "  [dry] nft -f $IPS_DIR/ips.nft:"; sed 's/^/    /' "$nft"
    c_dim "  [dry] systemd-юнит relabel-ips (адреса + nft при загрузке)"
    rm -f "$nft"; return 0
  fi

  nft -c -f "$nft" || { rm -f "$nft"; die "nft отверг правила (см. выше) — ничего не применено"; }
  mkdir -p "$IPS_DIR"
  install -m 0644 "$nft" "$IPS_DIR/ips.nft"; rm -f "$nft"
  cat > "$IPS_DIR/apply.sh" <<APPLY_EOF
#!/bin/sh
# сгенерировано relabel ips; адреса + правила nft
IFC="\$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if (\$i == "dev") { print \$(i + 1); exit }}')"
for a in $(printf '%s ' "${ins[@]}" "${outs[@]}"); do
  ip -4 addr show dev "\$IFC" | grep -q " \$a/" || ip addr add "\$a/32" dev "\$IFC"
done
/usr/sbin/nft -f $IPS_DIR/ips.nft
APPLY_EOF
  chmod 0755 "$IPS_DIR/apply.sh"
  cat > "$IPS_UNIT" <<UNIT_EOF
[Unit]
Description=relabel ips: входные/выходные адреса ноды
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$IPS_DIR/apply.sh
ExecStop=/usr/sbin/nft delete table inet relabel_ips

[Install]
WantedBy=multi-user.target
UNIT_EOF
  for x in "${add[@]}"; do grep -qx "$x" "$IPS_STATE_FILE" 2>/dev/null || echo "$x" >> "$IPS_STATE_FILE"; done
  systemctl daemon-reload
  systemctl enable relabel-ips.service >/dev/null 2>&1
  systemctl restart relabel-ips.service || die "relabel-ips не применился: journalctl -u relabel-ips"
  c_grn "· применено: юнит relabel-ips, правила $IPS_DIR/ips.nft"

  echo; c_grn "════ проверка ════"
  ip -4 -br addr show dev "$ifc" | sed 's/^/  /'
  if [ -n "$out" ]; then
    local seen; seen="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [ "$seen" = "$out" ]; then c_grn "  сайты видят $seen ✓"; else c_yel "  сайты видят ${seen:-нет ответа} (ожидался $out) — хостер мог не пускать $out через общий шлюз"; fi
  fi
  if ip -6 route show default 2>/dev/null | grep -q .; then
    c_yel "  ВНИМАНИЕ: на сервере есть IPv6 по умолчанию — сайты с IPv6 увидят его, а не $out."
    c_dim "  Не нужен IPv6 наружу — отключи его исходящие или задай domainStrategy UseIPv4 в outbound."
  fi
  [ "${#ins[@]}" -gt 0 ] && c_dim "  VPN-порты ${ports[*]} отвечают только на: ${ins[*]}"
  cat <<IPS_EOF

════ в панели Remnawave ════
  Хосты — только на входные адреса (${ins[*]:-как есть}) или их домены.
  Выходной адрес${out:+ $out} нигде не указывать: ни в хостах, ни в DNS доменов заглушки.
  Откат: relabel ips-restore
IPS_EOF
}

cmd_ips_restore() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || [ "$DRY_RUN" = 1 ] || die "relabel ips-restore требует root"
  c_grn "· снимаю relabel-ips (правила nft, юнит)"
  run systemctl disable --now relabel-ips.service 2>/dev/null || true
  run nft delete table inet relabel_ips 2>/dev/null || true
  run rm -f "$IPS_UNIT"
  run rm -rf "$IPS_DIR"
  [ "$DRY_RUN" = 1 ] || systemctl daemon-reload
  local ifc x; ifc="$(default_iface)"
  if [ -f "$IPS_STATE_FILE" ]; then
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      c_dim "  снимаю адрес $x (вешали мы)"
      run ip addr del "$x/32" dev "$ifc" 2>/dev/null || true
    done < "$IPS_STATE_FILE"
    run rm -f "$IPS_STATE_FILE"
  fi
  c_grn "Откат ips завершён (адреса, повешенные вручную, не тронуты)."
}

usage() {
  cat <<'EOF'
relabel.sh — маскировка имён docker-контейнеров VPN-ноды

ОДНОЙ КОМАНДОЙ:
  relabel all [--dry-run]      применить ВСЁ маскирование (A→B→C→D)
  relabel all-with-accelerator [--dry-run] [--no-mask] [--no-selfsteal] [--no-block] [--no-antiscan]  (root!)
                               [--domains d1,d2] [--in A1,A2] [--out B] [--ports 443]
                               selfsteal+маскирование+optimize+protect+mobile443+sysmgr
                               (+ domains/ips, если заданы --domains / --in / --out;
                                то же через ENV: DOMAINS, IN_IPS, OUT_IP, VPN_PORTS)
                               --no-mask: не переименовывать; --no-selfsteal: не ставить заглушку
                               --no-block: без блокировщиков (protect + mobile443)
                               --no-antiscan: protect без portscan-бана и CrowdSec, без mobile443
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
  relabel ipfilter [--dry-run]  блок подсетей сканеров на весь сервер, меню `ipfilter` (root)
  relabel ipsni [--dry-run]     заглушка под хост «IP в SNI + фрагментация» + проверка (root)
  relabel domains d1 [d2 …] [--dry-run]
                               заглушка на несколько доменов (свой сертификат на каждый) + проверка
  relabel ips [--in A1,A2] [--out B] [--ports 443,8443] [--dry-run]   (root)
                               вход только на A1/A2 (VPN-порты на прочих IP дропаются),
                               выход в интернет с B (SNAT); недостающие IP вешает сам
  relabel ips-restore [--dry-run]  снять правила/юнит ips и повешенные им адреса
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
_args=("$@"); _pos=()
_i=0
while [ "$_i" -lt "${#_args[@]}" ]; do
  _a="${_args[$_i]}"; _v="${_args[$((_i + 1))]:-}"
  case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    --no-mask) NO_MASK=1 ;;
    --no-selfsteal) NO_SELFSTEAL=1 ;;
    --no-block|--no-firewall) NO_BLOCK=1 ;;
    --no-antiscan) NO_ANTISCAN=1 ;;
    --domains=*) OPT_DOMAINS="${_a#*=}" ;;
    --in=*)      OPT_IN="${_a#*=}" ;;
    --out=*)     OPT_OUT="${_a#*=}" ;;
    --ports=*)   OPT_PORTS="${_a#*=}" ;;
    --domains|--in|--out|--ports)
      case "$_v" in ""|--*) die "$_a: нужно значение" ;; esac
      case "$_a" in
        --domains) OPT_DOMAINS="$_v" ;; --in) OPT_IN="$_v" ;;
        --out) OPT_OUT="$_v" ;; --ports) OPT_PORTS="$_v" ;;
      esac
      _i=$((_i + 1)) ;;
    *) _pos+=("$_a") ;;
  esac
  _i=$((_i + 1))
done
# То же через переменные окружения (удобно в одной команде с SSH_PORT=… TCP_PORTS=…).
OPT_DOMAINS="${OPT_DOMAINS:-${DOMAINS:-}}"
OPT_IN="${OPT_IN:-${IN_IPS:-}}"
OPT_OUT="${OPT_OUT:-${OUT_IP:-}}"
OPT_PORTS="${OPT_PORTS:-${VPN_PORTS:-}}"
# relabel domains d1 d2 … — домены позиционно
if [ "${_pos[0]:-}" = domains ] && [ "${#_pos[@]}" -gt 1 ]; then
  OPT_DOMAINS="${OPT_DOMAINS:+$OPT_DOMAINS,}$(IFS=,; echo "${_pos[*]:1}")"
fi
set -- "${_pos[@]}"
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
  ipfilter)          cmd_ipfilter ;;
  ipsni)             cmd_ipsni ;;
  domains)           cmd_domains ;;
  ips)               cmd_ips ;;
  ips-restore)       cmd_ips_restore ;;
  ps)                cmd_ps ;;
  ""|-h|--help|help) usage ;;
  *) die "неизвестная команда: $1 (см. --help)" ;;
esac
