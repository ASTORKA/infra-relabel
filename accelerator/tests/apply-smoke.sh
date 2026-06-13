#!/usr/bin/env bash
#
# apply-smoke.sh — гоняет ПОЛНЫЙ apply-path protect.sh (DRY_RUN=0) под `set -u`
# со стабами вместо реальных nft/systemctl/apt/curl и с перенаправлением системных
# путей в /tmp. Ловит класс багов, который НЕ виден ни в `bash -n`, ни в shellcheck,
# ни в DRY_RUN-смоуке: unbound-переменные (set -u) в ветках, исполняемых только при
# реальном применении (установка модулей fleet/blocklists/ctguard, маркер, save_conf).
# Пример пойманного: $LIVE_FLOOR вместо $SG_CTG_LIVE_FLOOR в ctguard-сообщении.
#
# Не требует root/nft/systemd — переносим (CI и локально). Запуск: bash tests/apply-smoke.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sys" "$T/sbin" "$T/modload" "$T/conf" "$T/state" "$T/backup"
cp -r "$REPO_ROOT/scripts" "$T/scripts"

# Перенаправляем хардкод-системные пути на писабельные /tmp (portable sed: без -i).
P="$T/scripts/protect.sh"
sed -e "s#/etc/systemd/system/#$T/sys/#g" \
    -e "s#/usr/local/sbin/#$T/sbin/#g" \
    -e "s#/etc/modules-load.d/#$T/modload/#g" \
    "$P" > "$P.tmp" && mv "$P.tmp" "$P"

# Стаб-бинари (no-op) в PATH.
for c in systemctl modprobe nft systemd-run sysctl ss conntrack; do
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
# curl падает → сетевые fetch (crowdsec/blocklist/fleet) деградируют мягко, не висят.
printf '#!/bin/sh\nexit 1\n' > "$T/bin/curl"; chmod +x "$T/bin/curl"
# cscli намеренно НЕ стабим → CrowdSec-тело пропускается (его хардкод-пути не трогаем).

# Глушим root/os/iface-детекты и переносим CONF_DIR/STATE_DIR.
cat >> "$T/scripts/lib/common.sh" <<STUB
require_root(){ :; }
detect_os(){ OS_ID=debian; OS_VER=12; OS_CODENAME=bookworm; }
default_iface(){ echo eth0; }
detect_ssh_port(){ echo 22; }
ssh_client_ip(){ echo "203.0.113.9"; }
apt_install(){ :; }
backup_dir(){ echo "$T/backup"; }
CONF_DIR="$T/conf"
STATE_DIR="$T/state"
STUB

export PATH="$T/bin:$PATH"
LOG="$T/apply.log"

# Полный apply со ВСЕМИ v3.0-модулями включёнными (CrowdSec off — его пути хардкод).
set +e
ENABLE_BLOCKLISTS=1 BLOCK_TOR=1 ENABLE_BANONCE=1 ENABLE_CTGUARD=1 SG_CTG_ENFORCE=0 \
  FLEET_SYNC=1 PANEL_URL=https://panel.example.com PANEL_TOKEN=tok \
  WHITELIST="1.2.3.4,2001:db8::1" NODE_PORT_WHITELIST_ONLY=1 ENABLE_CROWDSEC=0 \
  ENABLE_SYNPROXY=1 NONINTERACTIVE=1 DRY_RUN=0 \
  bash "$T/scripts/protect.sh" >"$LOG" 2>&1
rc=$?
set -e

fail=0
if [ "$rc" -ne 0 ]; then echo "[x] apply упал (exit $rc)"; fail=1; fi
if grep -qiE 'unbound variable|bad substitution' "$LOG"; then echo "[x] найдена unbound-переменная:"; grep -iE 'unbound variable|bad substitution' "$LOG"; fail=1; fi
# ключевые блоки должны были отработать
for marker in 'fleet-sync включён' 'блоклисты включены' 'ctguard в OBSERVE' 'Готово'; do
    grep -qF "$marker" "$LOG" || { echo "[x] не достигнут блок: '$marker'"; fail=1; }
done
# артефакты на месте
for f in conf/protect.conf conf/ctguard.conf conf/peers.env sbin/sys-peers-sync sbin/sys-blocklist-update sbin/sys-ctguard; do
    [ -e "$T/$f" ] || { echo "[x] не создан артефакт: $f"; fail=1; }
done

if [ "$fail" -ne 0 ]; then
    echo "=== ХВОСТ ЛОГА ==="; tail -25 "$LOG"
    echo "APPLY-SMOKE: FAIL"; exit 1
fi
echo "APPLY-SMOKE: OK (полный apply-path protect.sh чист под set -u, все модули и артефакты на месте)"
