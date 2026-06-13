#!/usr/bin/env bash
#
# rollback.sh — откат optimize / protect.
# Бэкапы оригиналов остаются в /var/backups/sysguard/.
#
# ENV:
#   SG_REMOVE_XANMOD=1   попытаться удалить пакет XanMod (только если сейчас грузимся НЕ с него)
#   SG_PURGE_CROWDSEC=1  удалить CrowdSec и bouncer (по умолчанию оставляем — это отдельный IPS)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root
WHAT="${1:-all}"

rollback_optimize() {
    title "Откат: ⚡ optimize"
    rm -f /etc/sysctl.d/99-sysguard.conf /etc/sysctl.d/99-sysguard-conntrack.conf
    rm -f /etc/modules-load.d/sys-bbr.conf /etc/modules-load.d/sys-conntrack.conf
    rm -f /etc/systemd/system.conf.d/sys-limits.conf /etc/systemd/user.conf.d/sys-limits.conf
    rm -f /etc/systemd/journald.conf.d/sys-size.conf
    sed -i '/# === sysguard ===/,/# === \/sysguard ===/d' /etc/security/limits.conf 2>/dev/null || true

    for svc in sys-rps sys-nic-tune sys-cpu-perf sys-thp-off sys-zram sys-mss-clamp; do
        systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$svc.service"
    done
    rm -f /usr/local/sbin/sys-rps-setup /usr/local/sbin/sys-zram-setup
    # MSS-clamp: снять свою таблицу
    nft delete table inet sys_mss 2>/dev/null || true
    rm -f "$CONF_DIR/sys_mss.nft"

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true
    systemctl restart systemd-journald 2>/dev/null || true

    # XanMod-ядро: удаляем ТОЛЬКО если сейчас работаем не на нём (иначе оставим как есть)
    if [[ -f "$STATE_DIR/xanmod.pkg" ]]; then
        local pkg; pkg="$(cat "$STATE_DIR/xanmod.pkg")"
        if [[ "${SG_REMOVE_XANMOD:-0}" == "1" ]] && ! uname -r | grep -qi xanmod; then
            info "Удаляю XanMod-пакет $pkg ..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$pkg" >/dev/null 2>&1 || warn "не удалил $pkg"
            update-grub >/dev/null 2>&1 || true
            # репозиторий и ключ больше не нужны — чистим, чтобы apt не ругался на suite
            rm -f /etc/apt/sources.list.d/xanmod*.list /etc/apt/keyrings/xanmod-archive-keyring.gpg
            apt-get update -qq 2>/dev/null || true
        else
            warn "XanMod ($pkg) оставлен. Сейчас грузимся: $(uname -r)."
            warn "Чтобы убрать: загрузись со стокового ядра и запусти SG_REMOVE_XANMOD=1 rollback optimize."
        fi
    fi
    rm -f "$STATE_DIR/optimize.installed" "$CONF_DIR/optimize.conf"
    ok "optimize откатан (значения sysctl вернутся к дефолтам; XanMod — по флагу)"
}

rollback_protect() {
    title "Откат: 🛡 protect"
    systemctl stop sys-fw-safety.timer 2>/dev/null || true
    [[ -f "$STATE_DIR/sys-fw-safety.pid" ]] && { kill "$(cat "$STATE_DIR/sys-fw-safety.pid")" 2>/dev/null || true; }
    [[ -f /tmp/sys-fw-safety.pid ]] && { kill "$(cat /tmp/sys-fw-safety.pid)" 2>/dev/null || true; }
    rm -f "$STATE_DIR/sys-fw-safety.pid" "$STATE_DIR/sys-fw-safety.log" /tmp/sys-fw-safety.pid /tmp/sys-fw-safety.log 2>/dev/null || true

    # v3.0 модули: fleet-sync / blocklists / ctguard — снимаем таймеры/сервисы
    for unit in sys-firewall sys-peers-sync sys-blocklist sys-ctguard; do
        systemctl disable --now "$unit.service" >/dev/null 2>&1 || true
        systemctl disable --now "$unit.timer"   >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"
    done
    systemctl daemon-reload

    # удаляем ТОЛЬКО свои таблицы — CrowdSec/Docker не трогаем
    nft delete table inet sysguard  2>/dev/null || true
    nft delete table inet sys_ctguard 2>/dev/null || true
    rm -f "$CONF_DIR/sysguard.nft"
    rm -f /usr/local/sbin/sys-fw-status /usr/local/sbin/sys-fw-top-talkers \
          /usr/local/sbin/sys-peers-sync /usr/local/sbin/sys-blocklist-update /usr/local/sbin/sys-ctguard
    rm -f /etc/modules-load.d/sys-synproxy.conf "$STATE_DIR/.synproxy-degraded"
    # конфиги: persisted protect.conf, ctguard.conf, токен панели peers.env (custom-blocklist.txt — данные оператора, оставляем)
    rm -f "$STATE_DIR/protect.installed" "$CONF_DIR/protect.conf" "$CONF_DIR/ctguard.conf" "$CONF_DIR/peers.env"
    [[ -f "$CONF_DIR/custom-blocklist.txt" ]] && info "оставлен $CONF_DIR/custom-blocklist.txt (данные оператора)"
    ok "sysguard/sys_ctguard удалены, сервисы и таймеры сняты"

    if [[ "${SG_PURGE_CROWDSEC:-0}" == "1" ]]; then
        warn "Удаляю CrowdSec и bouncer..."
        systemctl disable --now crowdsec-firewall-bouncer crowdsec >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq crowdsec-firewall-bouncer-nftables crowdsec >/dev/null 2>&1 || true
        nft delete table ip crowdsec 2>/dev/null || true
        nft delete table ip6 crowdsec6 2>/dev/null || true
        rm -f /etc/crowdsec/parsers/s02-enrich/sys-whitelist.yaml /etc/crowdsec/acquis.d/sys-sshd.yaml
        ok "CrowdSec удалён"
    else
        info "CrowdSec оставлен работать (SG_PURGE_CROWDSEC=1 чтобы удалить)."
        rm -f /etc/crowdsec/parsers/s02-enrich/sys-whitelist.yaml /etc/crowdsec/acquis.d/sys-sshd.yaml 2>/dev/null || true
        systemctl reload crowdsec >/dev/null 2>&1 || true
    fi
}

case "$WHAT" in
    optimize) rollback_optimize ;;
    protect)  rollback_protect ;;
    all)      rollback_protect; rollback_optimize ;;
    *) err "Использование: $0 [optimize|protect|all]"; exit 1 ;;
esac
ok "Бэкапы остаются в /var/backups/sysguard/"
