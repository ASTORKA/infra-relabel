#!/usr/bin/env bash
#
# bootstrap.sh — первичная подготовка чистого Debian/Ubuntu под VPN-ноду.
#
# Вендорено и переработано из vpn-bootstrap (MIT, см. bootstrap/LICENSE).
# Здесь только то, чего нет в accelerator/: XanMod, sysctl, RPS/RFS, irqbalance,
# conntrack и anti-flood уже делает `accelerator optimize/protect`, а
# blocklist'ы на весь хост — `netguard/`.
#
# Что делает (каждый шаг идемпотентен, повторный запуск безопасен):
#   1. имя узла (+ /etc/hosts, + запрет cloud-init перетирать его);
#   2. apt update/upgrade + пакеты администрирования (htop, nload, iftop, tcpdump…);
#   3. Docker (официальный get.docker.com), если его ещё нет;
#   4. SSH: ключ root в authorized_keys, вход только по ключу, порт, MaxStartups,
#      проверка `sshd -t` с автооткатом; учитывает sshd_config.d и ssh.socket;
#   5. Speedtest (Ookla CLI, бинарь в /usr/local/bin);
#   6. опционально: Oh My Zsh + Powerlevel10k для root, отключение IPv6.
#
# Запуск:  sudo bash bootstrap/bootstrap.sh         (интерактивно)
#          relabel bootstrap                        (то же через relabel)
#
# ENV (для NONINTERACTIVE=1 — без вопросов):
#   BS_HOSTNAME=node-1        имя узла (пусто — оставить текущее)
#   SSH_PORT=22               порт SSH (пусто — оставить текущий)
#   SSH_KEY="ssh-ed25519 …"   открытый ключ для root (пусто — не добавлять)
#   BS_UPGRADE=1              apt-get upgrade
#   BS_DOCKER=1               ставить Docker, если нет
#   BS_SSH=1                  харденинг SSH
#   BS_SPEEDTEST=1            ставить speedtest
#   BS_ZSH=0                  Oh My Zsh + Powerlevel10k для root
#   BS_DISABLE_IPV6=0         отключить IPv6 (sysctl)
#   BS_STATE_FILE=…           куда сохранить выбранный порт SSH (читает relabel)
#   GH_PROXY=https://gh-proxy.com/   прокси-префикс для github (пусто — напрямую)
#   DRY_RUN=1                 только показать план, ничего не менять
#
set -euo pipefail

GH_PROXY="${GH_PROXY-https://gh-proxy.com/}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
DRY_RUN="${DRY_RUN:-0}"

BS_HOSTNAME="${BS_HOSTNAME:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_KEY="${SSH_KEY:-}"
BS_UPGRADE="${BS_UPGRADE:-1}"
BS_DOCKER="${BS_DOCKER:-1}"
BS_SSH="${BS_SSH:-1}"
BS_SPEEDTEST="${BS_SPEEDTEST:-1}"
BS_ZSH="${BS_ZSH:-}"
BS_DISABLE_IPV6="${BS_DISABLE_IPV6:-}"
BS_STATE_FILE="${BS_STATE_FILE:-/var/lib/sysguard/bootstrap.env}"

SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
SSHD_DROPIN="$SSHD_DROPIN_DIR/00-sys-hardening.conf"
SYSCTL_IPV6_FILE=/etc/sysctl.d/99-sys-disable-ipv6.conf
BACKUP_DIR="/var/backups/sys-bootstrap/$(date +%Y%m%d-%H%M%S)"

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }
title() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()   { c_red "Ошибка: $*" >&2; exit 1; }

gh_url() { printf '%s%s' "$GH_PROXY" "$1"; }

is_yes() { [[ "${1:-}" =~ ^([yY]|[yY][eE][sS]|1|д|Д|да|Да|ДА)$ ]]; }

# ask_yn <переменная> <вопрос> <дефолт 0|1> — спрашивает, только если переменная пуста.
ask_yn() {
  local var="$1" q="$2" def="$3" ans hint
  [[ -n "${!var}" ]] && return 0
  if [[ "$NONINTERACTIVE" == 1 || ! -t 0 ]]; then printf -v "$var" '%s' "$def"; return 0; fi
  [[ "$def" == 1 ]] && hint="Д/н" || hint="д/Н"
  read -r -p "$q [$hint]: " ans
  if [[ -z "$ans" ]]; then printf -v "$var" '%s' "$def"
  elif is_yes "$ans"; then printf -v "$var" 1
  else printf -v "$var" 0; fi
}

current_hostname() { hostnamectl --static 2>/dev/null || hostname; }

current_ssh_port() {
  local p=""
  command -v sshd >/dev/null 2>&1 && p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  [[ -z "$p" ]] && p="$(ss -tnlp 2>/dev/null | awk '/sshd|"ssh"/{n=split($4,a,":"); print a[n]; exit}')"
  echo "${p:-22}"
}

valid_hostname() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ && "$1" != *..* ]]; }
valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_pubkey()   {
  [[ "$1" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

ask_inputs() {
  local cur ans
  cur="$(current_hostname)"
  if [[ -z "$BS_HOSTNAME" && "$NONINTERACTIVE" != 1 && -t 0 ]]; then
    while true; do
      read -r -p "Имя узла [$cur]: " ans; ans="${ans:-$cur}"
      valid_hostname "$ans" && { BS_HOSTNAME="$ans"; break; }
      c_yel "Некорректное имя: латиница, цифры, точки, дефисы."
    done
  fi
  [[ -z "$BS_HOSTNAME" ]] && BS_HOSTNAME="$cur"
  valid_hostname "$BS_HOSTNAME" || die "BS_HOSTNAME '$BS_HOSTNAME' некорректно"

  ask_yn BS_SSH "Настроить SSH (вход только по ключу, порт, лимиты)?" 1
  if [[ "$BS_SSH" == 1 ]]; then
    cur="$(current_ssh_port)"
    if [[ -z "$SSH_PORT" && "$NONINTERACTIVE" != 1 && -t 0 ]]; then
      while true; do
        read -r -p "Порт SSH [$cur]: " ans; ans="${ans:-$cur}"
        valid_port "$ans" && { SSH_PORT="$ans"; break; }
        c_yel "Порт — число 1..65535."
      done
    fi
    [[ -z "$SSH_PORT" ]] && SSH_PORT="$cur"
    valid_port "$SSH_PORT" || die "SSH_PORT '$SSH_PORT' некорректен"

    if [[ -z "$SSH_KEY" && "$NONINTERACTIVE" != 1 && -t 0 ]]; then
      while true; do
        read -r -p "Открытый SSH-ключ для root (Enter — не добавлять): " ans
        [[ -z "$ans" ]] && break
        valid_pubkey "$ans" && { SSH_KEY="$ans"; break; }
        c_yel "Это не открытый ключ OpenSSH (одна строка: тип ключ [комментарий])."
      done
    fi
    [[ -z "$SSH_KEY" ]] || valid_pubkey "$SSH_KEY" || die "SSH_KEY не похож на открытый ключ OpenSSH"
  fi

  ask_yn BS_ZSH "Поставить Oh My Zsh + Powerlevel10k для root?" 0
  ask_yn BS_DISABLE_IPV6 "Отключить IPv6?" 0
}

print_plan() {
  title "План"
  echo "  имя узла:        $BS_HOSTNAME"
  echo "  apt upgrade:     $BS_UPGRADE"
  echo "  Docker:          $BS_DOCKER"
  if [[ "$BS_SSH" == 1 ]]; then
    echo "  SSH:             порт $SSH_PORT, вход по ключу, ключ: $([[ -n "$SSH_KEY" ]] && echo "добавить (${SSH_KEY%% *})" || echo "не добавлять")"
  else
    echo "  SSH:             не трогать"
  fi
  echo "  speedtest:       $BS_SPEEDTEST"
  echo "  zsh + p10k:      $BS_ZSH"
  echo "  отключить IPv6:  $BS_DISABLE_IPV6"
}

# ─── 1. имя узла ─────────────────────────────────────────────────────────────
configure_hostname() {
  title "Имя узла"
  local entry="127.0.1.1 $BS_HOSTNAME"
  if [[ "$(current_hostname)" != "$BS_HOSTNAME" ]]; then
    hostnamectl set-hostname "$BS_HOSTNAME"
  fi
  if grep -Eq '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    grep -Fqx "$entry" /etc/hosts || sed -i -E "s/^127\.0\.1\.1[[:space:]].*/$entry/" /etc/hosts
  else
    printf '%s\n' "$entry" >> /etc/hosts
  fi
  # cloud-init на многих VPS при каждой загрузке возвращает имя из метаданных.
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-sys-hostname.cfg
  fi
  c_grn "· имя узла: $BS_HOSTNAME"
}

# ─── 2. пакеты ───────────────────────────────────────────────────────────────
install_packages() {
  title "Пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if [[ "$BS_UPGRADE" == 1 ]]; then
    c_dim "· apt-get upgrade…"
    apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null
  fi
  local want=(curl wget ca-certificates gnupg sudo git vim htop nload iftop tcpdump
              kmod ethtool iproute2 lsb-release openssh-server ipset iptables)
  [[ "$BS_ZSH" == 1 ]] && want+=(zsh fonts-powerline)
  local p missing=()
  for p in "${want[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -Fqx 'install ok installed' || missing+=("$p")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    c_dim "· ставлю: ${missing[*]}"
    apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  fi
  c_grn "· пакеты на месте"
}

# ─── 3. Docker ───────────────────────────────────────────────────────────────
install_docker() {
  title "Docker"
  if command -v docker >/dev/null 2>&1; then
    c_dim "· Docker уже установлен ($(docker --version 2>/dev/null | head -1))"
  else
    local f; f="$(mktemp)"
    curl -fsSL --connect-timeout 20 --max-time 180 --retry 2 https://get.docker.com -o "$f" \
      || { rm -f "$f"; die "не скачал get.docker.com"; }
    sh "$f"
    rm -f "$f"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  c_grn "· Docker запущен"
}

# ─── 4. SSH ──────────────────────────────────────────────────────────────────
ssh_restart() {
  # Ubuntu 22.10+: sshd поднимается через ssh.socket, порт берётся генератором
  # из sshd_config при daemon-reload — без этого смена порта не применится.
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl restart ssh.service 2>/dev/null || true
  elif systemctl cat ssh.service >/dev/null 2>&1; then
    systemctl restart ssh.service
  else
    systemctl restart sshd.service
  fi
}

ssh_restore_backup() {
  cp -a "$BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
  rm -f "$SSHD_DROPIN"
  if [[ -d "$BACKUP_DIR/sshd_config.d" ]]; then
    cp -a "$BACKUP_DIR/sshd_config.d/." "$SSHD_DROPIN_DIR/"
  fi
}

configure_ssh() {
  title "SSH"
  local sshd auth=/root/.ssh/authorized_keys has_key=0 cur_port port_note=""
  sshd="$(command -v sshd || echo /usr/sbin/sshd)"
  [[ -x "$sshd" ]] || die "sshd не найден"
  mkdir -p /run/sshd

  install -d -m 700 /root/.ssh
  touch "$auth"; chmod 600 "$auth"
  if [[ -n "$SSH_KEY" ]]; then
    if grep -Fqx "$SSH_KEY" "$auth"; then c_dim "· ключ уже есть в authorized_keys"
    else printf '%s\n' "$SSH_KEY" >> "$auth"; c_grn "· ключ добавлен в authorized_keys"; fi
  fi
  grep -Eq '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$auth" && has_key=1

  # Смена порта при уже стоящем firewall accelerator'а (protect) отрежет SSH:
  # новый порт в nftables не открыт. В этом случае порт не трогаем.
  cur_port="$(current_ssh_port)"
  if [[ "$SSH_PORT" != "$cur_port" ]] && command -v nft >/dev/null 2>&1 \
     && nft list table inet sysguard >/dev/null 2>&1; then
    c_yel "· firewall sysguard уже активен — порт SSH оставляю $cur_port (иначе потеряешь доступ)."
    c_yel "  Сменить порт: сначала SSH_PORT=$SSH_PORT accelerator protect, потом повторить bootstrap."
    SSH_PORT="$cur_port"
  fi
  if [[ "$SSH_PORT" != "$cur_port" ]] && command -v ufw >/dev/null 2>&1 \
     && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$SSH_PORT/tcp" >/dev/null && port_note=" (открыт в ufw)"
  fi

  mkdir -p "$BACKUP_DIR"
  cp -a "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config"
  [[ -d "$SSHD_DROPIN_DIR" ]] && cp -a "$SSHD_DROPIN_DIR" "$BACKUP_DIR/sshd_config.d"

  # Port накапливается (каждая строка — ещё один порт), поэтому все чужие
  # Port-строки комментируем, а порт задаём один раз в нашем блоке.
  local f
  for f in "$SSHD_CONFIG" "$SSHD_DROPIN_DIR"/*.conf; do
    [[ -f "$f" && "$f" != "$SSHD_DROPIN" ]] || continue
    sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+)/# sys-bootstrap: \1/' "$f"
  done

  local block
  block="Port $SSH_PORT
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 100:30:200"
  if [[ "$has_key" == 1 ]]; then
    block+="
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no"
  else
    c_yel "· в authorized_keys нет ни одного ключа — вход по паролю НЕ отключаю (иначе потеряешь доступ)"
  fi

  # В sshd побеждает первое значение параметра. Drop-in 00-* подключается
  # Include'ом в самом начале sshd_config и перекрывает 50-cloud-init.conf и т.п.
  if grep -Eq "^[[:space:]]*Include[[:space:]]+${SSHD_DROPIN_DIR//./\\.}/\\*\\.conf" "$SSHD_CONFIG"; then
    printf '# Сгенерировано bootstrap.sh (infra-relabel). Бэкап: %s\n%s\n' "$BACKUP_DIR" "$block" > "$SSHD_DROPIN"
    chmod 644 "$SSHD_DROPIN"
  else
    # Без Include — вставляем блок в начало sshd_config (до любых Match).
    sed -i '/^# === sys-bootstrap ===$/,/^# === \/sys-bootstrap ===$/d' "$SSHD_CONFIG"
    local tmp; tmp="$(mktemp)"
    { printf '# === sys-bootstrap ===\n%s\n# === /sys-bootstrap ===\n' "$block"; cat "$SSHD_CONFIG"; } > "$tmp"
    chown --reference="$SSHD_CONFIG" "$tmp"; chmod --reference="$SSHD_CONFIG" "$tmp"
    mv "$tmp" "$SSHD_CONFIG"
  fi

  if ! "$sshd" -t; then
    ssh_restore_backup
    die "sshd -t не прошёл — конфиг SSH восстановлен из $BACKUP_DIR"
  fi
  ssh_restart
  local eff_port eff_pw
  eff_port="$("$sshd" -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd, -)"
  eff_pw="$("$sshd" -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  c_grn "· SSH: порт ${eff_port:-?}${port_note}, пароли: ${eff_pw:-?}, бэкап: $BACKUP_DIR"
  if [[ "$SSH_PORT" != "$cur_port" ]]; then
    c_yel "· порт SSH сменён $cur_port → $SSH_PORT. НЕ закрывай текущую сессию, пока не проверишь:"
    c_yel "    ssh -p $SSH_PORT root@<IP>"
  fi
}

# ─── 5. speedtest ────────────────────────────────────────────────────────────
install_speedtest() {
  title "Speedtest"
  if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>/dev/null | grep -q Ookla; then
    c_dim "· speedtest уже установлен"; return 0
  fi
  local a tmp
  case "$(uname -m)" in
    x86_64) a=x86_64 ;; aarch64|arm64) a=aarch64 ;; armv7l) a=armhf ;;
    *) c_yel "· архитектура $(uname -m) не поддерживается — пропуск"; return 0 ;;
  esac
  tmp="$(mktemp -d)"
  if curl -fsSL --connect-timeout 20 --max-time 120 \
       "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$a.tgz" -o "$tmp/s.tgz" \
     && tar -xzf "$tmp/s.tgz" -C "$tmp" speedtest; then
    install -m 755 "$tmp/speedtest" /usr/local/bin/speedtest
    c_grn "· speedtest → /usr/local/bin/speedtest (первый запуск: speedtest --accept-license)"
  else
    c_yel "· не удалось скачать speedtest — пропуск"
  fi
  rm -rf "$tmp"
}

# ─── 6. zsh ──────────────────────────────────────────────────────────────────
configure_zsh() {
  title "Zsh + Powerlevel10k"
  local custom=/root/.oh-my-zsh/custom f
  if [[ ! -d /root/.oh-my-zsh ]]; then
    f="$(mktemp)"
    curl -fsSL --connect-timeout 20 --max-time 120 \
      "$(gh_url https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -o "$f" \
      || { rm -f "$f"; c_yel "· не скачал Oh My Zsh — пропуск"; return 0; }
    # Установщик сам делает git clone с github — заворачиваем через прокси.
    HOME=/root RUNZSH=no CHSH=no REMOTE="$(gh_url https://github.com/ohmyzsh/ohmyzsh.git)" sh "$f"
    rm -f "$f"
  fi
  [[ -d "$custom/themes/powerlevel10k" ]] \
    || git clone -q --depth=1 "$(gh_url https://github.com/romkatv/powerlevel10k.git)" "$custom/themes/powerlevel10k"
  [[ -d "$custom/plugins/zsh-autosuggestions" ]] \
    || git clone -q --depth=1 "$(gh_url https://github.com/zsh-users/zsh-autosuggestions)" "$custom/plugins/zsh-autosuggestions"
  [[ -d "$custom/plugins/zsh-syntax-highlighting" ]] \
    || git clone -q --depth=1 "$(gh_url https://github.com/zsh-users/zsh-syntax-highlighting)" "$custom/plugins/zsh-syntax-highlighting"
  if [[ -f /root/.zshrc ]]; then
    sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' /root/.zshrc
    if grep -Eq '^plugins=\(' /root/.zshrc; then
      sed -i 's/^plugins=(.*/plugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)/' /root/.zshrc
    else
      printf '\nplugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)\n' >> /root/.zshrc
    fi
  fi
  [[ "$(getent passwd root | cut -d: -f7)" == "$(command -v zsh)" ]] || chsh -s "$(command -v zsh)" root
  c_grn "· zsh для root готов (после входа: p10k configure)"
}

# ─── 7. IPv6 ─────────────────────────────────────────────────────────────────
disable_ipv6() {
  title "IPv6"
  printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' > "$SYSCTL_IPV6_FILE"
  sysctl -e -p "$SYSCTL_IPV6_FILE" >/dev/null
  c_grn "· IPv6 отключён ($SYSCTL_IPV6_FILE; вернуть — удалить файл и sysctl --system)"
}

save_state() {
  mkdir -p "$(dirname "$BS_STATE_FILE")"
  {
    echo "# bootstrap.sh $(date -Is)"
    echo "BS_HOSTNAME=$BS_HOSTNAME"
    [[ "$BS_SSH" == 1 ]] && echo "SSH_PORT=$SSH_PORT"
    echo "BS_BACKUP_DIR=$BACKUP_DIR"
  } > "$BS_STATE_FILE"
}

main() {
  [[ -f /etc/os-release ]] || die "нет /etc/os-release"
  # shellcheck disable=SC1091
  case "$(. /etc/os-release; echo "${ID:-}")" in
    debian|ubuntu) ;;
    *) die "поддерживаются только Debian/Ubuntu" ;;
  esac
  if [[ "$DRY_RUN" != 1 && "${EUID:-$(id -u)}" -ne 0 ]]; then die "запусти от root"; fi

  ask_inputs
  print_plan
  if [[ "$DRY_RUN" == 1 ]]; then echo; c_yel "DRY-RUN: ничего не изменено."; return 0; fi

  configure_hostname
  install_packages
  [[ "$BS_DOCKER" == 1 ]] && install_docker
  [[ "$BS_SSH" == 1 ]] && configure_ssh
  [[ "$BS_SPEEDTEST" == 1 ]] && install_speedtest
  [[ "$BS_ZSH" == 1 ]] && configure_zsh
  [[ "$BS_DISABLE_IPV6" == 1 ]] && disable_ipv6
  save_state

  title "ГОТОВО"
  c_grn "Хост подготовлен."
  [[ "$BS_SSH" == 1 ]] && c_dim "Подключение: ssh -p $SSH_PORT root@<IP>"
  c_dim "Дальше: relabel all-with-accelerator (порт SSH $SSH_PORT подхватится автоматически)."
}

main "$@"
