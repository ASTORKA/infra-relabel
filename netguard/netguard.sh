#!/usr/bin/env bash
#
# netguard.sh — blocklist Traffic Guard (гос-сети + антисканеры) на ВЕСЬ хост.
#
# Вендорено и переработано из vpn-bootstrap (update-traffic-guard.sh, MIT —
# см. bootstrap/LICENSE). Отличие от mobile443: mobile443 дропает входящие
# только на VPN-портах, а netguard режет эти сети на всех портах и в обе
# стороны — входящие (INPUT/FORWARD/DOCKER-USER, src → DROP) и исходящие
# (OUTPUT/FORWARD/DOCKER-USER, dst → REJECT), чтобы нода и её клиенты не
# ходили в эти сети. Исходящую блокировку можно выключить (NG_OUTBOUND=0).
#
# Команды:
#   netguard.sh install   поставить: скрипт, конфиг, systemd-юнит + ежедневный таймер
#   netguard.sh update    скачать листы и атомарно заменить ipset (ipset swap)
#   netguard.sh apply     восстановить правила из кэша без скачивания (при загрузке)
#   netguard.sh status    состояние набора, правил и таймера
#   netguard.sh remove    снять правила, набор, юниты и файлы
#
# Всё в нейтральной схеме sys-*: ipset sys_netguard, цепочки SYS_NETGUARD_IN/OUT,
# юниты sys-netguard.service/.timer, конфиг /etc/default/sys-netguard.
#
# ENV (сохраняются в конфиг при install):
#   GH_PROXY=https://gh-proxy.com/   прокси-префикс для github (пусто — напрямую)
#   NG_OUTBOUND=1                    блокировать исходящие в эти сети
#   NG_LISTS="government_networks antiscanner"
#   NG_BASE_URL=…                    откуда брать *.list
#   WHITELIST="1.2.3.4,5.6.7.0/24"   никогда не блокировать (IP панели/админа)
#   DRY_RUN=1
#
set -euo pipefail

NAME=sys-netguard
SET=sys_netguard
CHAIN_IN=SYS_NETGUARD_IN
CHAIN_OUT=SYS_NETGUARD_OUT
CONF=/etc/default/$NAME
TARGET=/usr/local/sbin/$NAME
DATA_DIR=/var/lib/$NAME
CACHE="$DATA_DIR/current.list"
LOCK=/run/lock/$NAME.lock
MAXELEM=500000
HASHSIZE=65536
DRY_RUN="${DRY_RUN:-0}"

# Конфиг читаем до ENV-дефолтов: ENV перекрывает сохранённое.
_env_gh="${GH_PROXY-__unset__}"; _env_out="${NG_OUTBOUND:-}"; _env_lists="${NG_LISTS:-}"
_env_base="${NG_BASE_URL:-}"; _env_wl="${WHITELIST-__unset__}"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
[[ "$_env_gh" != __unset__ ]] && GH_PROXY="$_env_gh"
[[ -n "$_env_out" ]] && NG_OUTBOUND="$_env_out"
[[ -n "$_env_lists" ]] && NG_LISTS="$_env_lists"
[[ -n "$_env_base" ]] && NG_BASE_URL="$_env_base"
[[ "$_env_wl" != __unset__ ]] && WHITELIST="$_env_wl"
GH_PROXY="${GH_PROXY-https://gh-proxy.com/}"
NG_OUTBOUND="${NG_OUTBOUND:-1}"
NG_LISTS="${NG_LISTS:-government_networks antiscanner}"
NG_BASE_URL="${NG_BASE_URL:-${GH_PROXY}https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public}"
WHITELIST="${WHITELIST:-}"

log() { printf '[%s] %s\n' "$NAME" "$*" >&2; logger -t "$NAME" -- "$*" 2>/dev/null || true; }
die() { log "ошибка: $*"; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "нужен root"; }
need() { command -v "$1" >/dev/null 2>&1 || die "нет команды $1"; }

ensure_tools() {
  if ! command -v ipset >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
    log "ставлю ipset/iptables…"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ipset iptables >/dev/null
  fi
  need ipset; need iptables; need curl; need flock
}

# ─── правила ─────────────────────────────────────────────────────────────────
ensure_set() {
  ipset create "$SET" hash:net family inet hashsize "$HASHSIZE" maxelem "$MAXELEM" -exist
}

# Своя цепочка: whitelist → RETURN, набор → DROP/REJECT. Пересобирается целиком.
build_chains() {
  local ip
  iptables -N "$CHAIN_IN" 2>/dev/null || iptables -F "$CHAIN_IN"
  iptables -N "$CHAIN_OUT" 2>/dev/null || iptables -F "$CHAIN_OUT"
  for ip in ${WHITELIST//,/ }; do
    iptables -A "$CHAIN_IN"  -s "$ip" -j RETURN
    iptables -A "$CHAIN_OUT" -d "$ip" -j RETURN
  done
  iptables -A "$CHAIN_IN"  -m set --match-set "$SET" src -j DROP
  iptables -A "$CHAIN_OUT" -m set --match-set "$SET" dst -j REJECT --reject-with icmp-net-prohibited
}

# jump <цепочка-хука> <наша-цепочка> — вставить переход первым правилом (идемпотентно).
jump() {
  iptables -C "$1" -j "$2" 2>/dev/null || iptables -I "$1" 1 -j "$2"
}
unjump() {
  while iptables -D "$1" -j "$2" 2>/dev/null; do :; done
}

ensure_rules() {
  ensure_set
  build_chains
  jump INPUT "$CHAIN_IN"
  jump FORWARD "$CHAIN_IN"
  if [[ "$NG_OUTBOUND" == 1 ]]; then
    jump OUTPUT "$CHAIN_OUT"
    jump FORWARD "$CHAIN_OUT"
  else
    unjump OUTPUT "$CHAIN_OUT"; unjump FORWARD "$CHAIN_OUT"
  fi
  # DOCKER-USER появляется, когда поднят Docker (трафик контейнеров идёт мимо INPUT).
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    jump DOCKER-USER "$CHAIN_IN"
    if [[ "$NG_OUTBOUND" == 1 ]]; then jump DOCKER-USER "$CHAIN_OUT"; else unjump DOCKER-USER "$CHAIN_OUT"; fi
  fi
}

remove_rules() {
  local c
  for c in INPUT FORWARD DOCKER-USER; do unjump "$c" "$CHAIN_IN"; done
  for c in OUTPUT FORWARD DOCKER-USER; do unjump "$c" "$CHAIN_OUT"; done
  for c in "$CHAIN_IN" "$CHAIN_OUT"; do
    iptables -F "$c" 2>/dev/null || true
    iptables -X "$c" 2>/dev/null || true
  done
  ipset destroy "$SET" 2>/dev/null || true
}

# ─── листы ───────────────────────────────────────────────────────────────────
# load_set <файл> — собрать временный набор из файла и атомарно подменить активный.
load_set() {
  local file="$1" tmp="${SET}_new" n
  n="$(grep -c . "$file" || true)"
  [[ "$n" -gt 0 ]] || die "пустой список — активный набор не трогаю"
  ensure_set
  ipset destroy "$tmp" 2>/dev/null || true
  {
    printf 'create %s hash:net family inet hashsize %s maxelem %s\n' "$tmp" "$HASHSIZE" "$MAXELEM"
    awk -v s="$tmp" '{print "add " s " " $0 " -exist"}' "$file"
  } | ipset restore -exist || { ipset destroy "$tmp" 2>/dev/null || true; die "ipset restore не прошёл"; }
  ipset swap "$tmp" "$SET"
  ipset destroy "$tmp"
  log "набор $SET: $n записей"
}

fetch_lists() {
  local out="$1" l tmp raw
  tmp="$(mktemp -d)"
  raw="$tmp/raw"; : > "$raw"
  for l in $NG_LISTS; do
    [[ "$l" =~ ^[A-Za-z0-9_.-]+$ ]] || { rm -rf "$tmp"; die "некорректное имя листа: $l"; }
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
         "$NG_BASE_URL/$l.list" -o "$tmp/$l"; then
      rm -rf "$tmp"; return 1
    fi
    cat "$tmp/$l" >> "$raw"; echo >> "$raw"
  done
  # Только IPv4-адреса/подсети: комментарии, пробелы, CRLF и мусор отбрасываем.
  sed -e 's/\r//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$raw" \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$' \
    | sort -u > "$out"
  rm -rf "$tmp"
}

cmd_update() {
  need_root; ensure_tools
  install -d -m 755 "$DATA_DIR" /run/lock
  exec 9>"$LOCK"
  flock -n 9 || { log "обновление уже идёт — выход"; exit 0; }
  local new="$DATA_DIR/new.list"
  if fetch_lists "$new" && [[ -s "$new" ]]; then
    mv "$new" "$CACHE"
    log "листы скачаны: $(wc -l < "$CACHE") подсетей"
  else
    rm -f "$new"
    [[ -s "$CACHE" ]] || die "не скачал листы и нет кэша ($NG_BASE_URL). Проверь GH_PROXY."
    log "не скачал листы — применяю кэш ($(wc -l < "$CACHE") подсетей)"
  fi
  load_set "$CACHE"
  ensure_rules
  log "готово (исходящие: $([[ "$NG_OUTBOUND" == 1 ]] && echo блок || echo не блок))"
}

# При загрузке: поднять набор из кэша сразу (без сети), затем попробовать обновить.
cmd_apply() {
  need_root; ensure_tools
  if [[ -s "$CACHE" ]]; then load_set "$CACHE"; ensure_rules; fi
  ( cmd_update ) || log "обновление не удалось — работаем на кэше"
}

write_conf() {
  cat > "$CONF" <<EOF
# sys-netguard: настройки (перезапиши и выполни: $TARGET update)
GH_PROXY="$GH_PROXY"
NG_OUTBOUND="$NG_OUTBOUND"
NG_LISTS="$NG_LISTS"
NG_BASE_URL="$NG_BASE_URL"
WHITELIST="$WHITELIST"
EOF
  chmod 644 "$CONF"
}

cmd_install() {
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry] install $0 → $TARGET, конфиг $CONF, юниты $NAME.service/.timer"
    echo "[dry] листы: $NG_LISTS из $NG_BASE_URL; исходящие=$NG_OUTBOUND; whitelist='${WHITELIST}'"
    return 0
  fi
  need_root; ensure_tools
  local self; self="$(readlink -f "$0")"
  [[ "$self" == "$TARGET" ]] || install -m 755 "$self" "$TARGET"
  install -d -m 755 "$DATA_DIR"
  write_conf

  cat > /etc/systemd/system/$NAME.service <<EOF
[Unit]
Description=system network blocklist
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$TARGET apply

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/$NAME-update.service <<EOF
[Unit]
Description=system network blocklist refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$TARGET update
EOF
  cat > /etc/systemd/system/$NAME.timer <<EOF
[Unit]
Description=system network blocklist daily refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=$NAME-update.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  # $NAME.service — при загрузке: набор из кэша сразу, без ожидания таймера.
  systemctl enable $NAME.service >/dev/null 2>&1
  systemctl enable --now $NAME.timer >/dev/null 2>&1
  "$TARGET" update
  log "установлено: $TARGET, таймер $NAME.timer (раз в сутки), конфиг $CONF"
}

cmd_remove() {
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry] снять юниты $NAME.*, правила $CHAIN_IN/$CHAIN_OUT, ipset $SET, файлы $TARGET $CONF $DATA_DIR"
    return 0
  fi
  need_root
  systemctl disable --now $NAME.timer $NAME.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/$NAME.service /etc/systemd/system/$NAME-update.service /etc/systemd/system/$NAME.timer
  systemctl daemon-reload
  if command -v iptables >/dev/null 2>&1; then remove_rules; fi
  rm -rf "$DATA_DIR" "$CONF"
  [[ "$(readlink -f "$0")" == "$TARGET" ]] || rm -f "$TARGET"
  log "удалено"
}

cmd_status() {
  echo "конфиг:    $CONF $([[ -f "$CONF" ]] && echo '(есть)' || echo '(нет — не установлен)')"
  echo "листы:     $NG_LISTS"
  echo "исходящие: $([[ "$NG_OUTBOUND" == 1 ]] && echo блокируются || echo не блокируются)"
  echo "whitelist: ${WHITELIST:-—}"
  if command -v ipset >/dev/null 2>&1 && ipset list -n 2>/dev/null | grep -qx "$SET"; then
    echo "ipset:     $SET, записей: $(ipset list "$SET" | awk -F': ' '/Number of entries/{print $2}')"
  else
    echo "ipset:     нет"
  fi
  local c
  for c in INPUT FORWARD OUTPUT DOCKER-USER; do
    iptables -S "$c" 2>/dev/null | grep -qE -- "-j ($CHAIN_IN|$CHAIN_OUT)" \
      && echo "правила:   $c → $(iptables -S "$c" | grep -oE "$CHAIN_IN|$CHAIN_OUT" | paste -sd, -)"
  done
  systemctl list-timers "$NAME.timer" --no-pager 2>/dev/null | sed -n '1,2p' || true
}

case "${1:-}" in
  install) cmd_install ;;
  update)  cmd_update ;;
  apply)   cmd_apply ;;
  status)  cmd_status ;;
  remove|uninstall) cmd_remove ;;
  *) sed -n '2,30p' "$0"; exit 1 ;;
esac
