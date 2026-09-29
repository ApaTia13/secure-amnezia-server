#!/bin/bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
info()  { echo -e "${CYAN}➜${NC} $1"; }
title() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
die()   { err "$1"; exit 1; }

CONFIG_MARKER="/etc/amnezia-hardening.conf"
LOGFILE="/var/log/amnezia-hardening-$(date +%Y%m%d-%H%M%S).log"
TS="$(date +%Y%m%d%H%M%S)"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-amnezia-hardening.conf"
NFT_CONF="/etc/nftables.conf"
INTERACTIVE_MSG="Скрипт требует интерактивного режима. Пожалуйста, скачайте скрипт и запустите его локально, либо используйте ssh -t"
APT_OPTS=(-y -qq -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold)

on_error() {
    local rc=$?
    err "Непредвиденная ошибка (код ${rc}) в строке $1. Выполнение остановлено."
}
trap 'on_error $LINENO' ERR
trap 'sleep 0.3' EXIT

require_tty() {
    if [[ ! -t 0 ]]; then
        err "$INTERACTIVE_MSG"
        echo -e "${YELLOW}Пример:${NC} curl -fsSLo secure-amnezia.sh <URL_СКРИПТА> && sudo bash secure-amnezia.sh"
        exit 1
    fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

ask() {
    local __var="$1" __prompt="$2" __reply=""
    require_tty
    if ! IFS= read -r -p "$__prompt" __reply; then
        echo
        die "Ввод прерван (EOF). Завершение."
    fi
    __reply="${__reply//$'\r'/}"
    printf -v "$__var" '%s' "$__reply"
}

confirm() {
    local answer=""
    ask answer "$1"
    answer="$(trim "$answer")"
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

tcp_port_in_use() {
    [[ -n "$(ss -H -tln "sport = :$1")" ]]
}

unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

if [[ $EUID -ne 0 ]]; then
    die "Скрипт должен выполняться от root (используйте sudo)."
fi

[[ -r /etc/os-release ]] || die "Не удалось определить операционную систему."
OS_ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
OS_VERSION="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
OS_CODENAME="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
OS_PRETTY="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}")"

[[ "$OS_ID" == "ubuntu" ]] || die "Скрипт предназначен строго для Ubuntu. Обнаружена: ${OS_PRETTY}"
case "$OS_VERSION" in
    22.04|24.04) ;;
    *) die "Поддерживаются только Ubuntu 22.04 и 24.04. Ваша версия: ${OS_VERSION}" ;;
esac

require_tty

install -m 600 /dev/null "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1
info "Логирование сохранено в: $LOGFILE"

exec 9>/run/lock/amnezia-hardening.lock
flock -n 9 || die "Другой экземпляр скрипта уже выполняется."

ok "Проверка root и ОС пройдена: ${OS_PRETTY}"

conf_get() {
    awk -F'"' -v k="$1" '$1 == k "=" {print $2; exit}' "$CONFIG_MARKER"
}

conf_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONFIG_MARKER"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_MARKER"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_MARKER"
    fi
    sed -i "s|^LAST_RUN=.*|LAST_RUN=\"$(date +%s)\"|" "$CONFIG_MARKER"
    chmod 600 "$CONFIG_MARKER"
}

list_has() {
    local x
    for x in $1; do
        [[ "$x" == "$2" ]] && return 0
    done
    return 1
}

list_add() {
    printf '%s\n' $1 "$2" | sort -nu | paste -sd' ' -
}

list_remove() {
    local x out=()
    for x in $1; do
        [[ "$x" == "$2" ]] || out+=("$x")
    done
    echo "${out[*]:-}"
}

latest_backup() {
    local f
    f="$(compgen -G "$1" | sort | tail -n1 || true)"
    printf '%s' "$f"
}

nft_commit() {
    local ssh="$1" udp_ports="$2" tcp_extras="$3"
    local tmp udp_line="" extras_lines="" p set_str stamp

    [[ -f "$NFT_CONF" ]] || { err "Файл $NFT_CONF не найден."; return 1; }

    if [[ -n "$udp_ports" ]]; then
        set_str="$(printf '%s\n' $udp_ports | sort -nu | paste -sd, - | sed 's/,/, /g')"
        udp_line="        udp dport { ${set_str} } accept"
    fi
    for p in $tcp_extras; do
        extras_lines+="        tcp dport ${p} accept comment \"amnezia-extra\"|"
    done

    tmp="$(mktemp)"
    if ! awk -v ssh="$ssh" -v udp="$udp_line" -v extras="$extras_lines" '
        /comment "amnezia-extra"/ { next }
        /^[[:space:]]*udp dport [{].*[}] accept[[:space:]]*$/ { next }
        /^[[:space:]]*tcp dport [0-9]+ accept[[:space:]]*$/ { sub(/dport [0-9]+/, "dport " ssh); print; next }
        /^[[:space:]]*meta l4proto icmp/ && !done {
            if (udp != "") print udp
            n = split(extras, a, "|")
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            done = 1
        }
        { print }
    ' "$NFT_CONF" > "$tmp"; then
        rm -f "$tmp"
        err "Не удалось подготовить новый файл правил."
        return 1
    fi

    if ! grep -qE "^[[:space:]]*tcp dport ${ssh} accept[[:space:]]*$" "$tmp"; then
        rm -f "$tmp"
        err "В $NFT_CONF не найдено правило SSH (tcp dport <порт> accept). Файл изменён вручную?"
        return 1
    fi
    if [[ -n "$udp_line" ]] && ! grep -qF -- "$udp_line" "$tmp"; then
        rm -f "$tmp"
        err "Не найдена точка вставки правил (meta l4proto icmp) в $NFT_CONF."
        return 1
    fi
    for p in $tcp_extras; do
        if ! grep -qF -- "tcp dport ${p} accept comment \"amnezia-extra\"" "$tmp"; then
            rm -f "$tmp"
            err "Не удалось вставить правило для tcp/${p}."
            return 1
        fi
    done

    if ! nft -c -f "$tmp"; then
        rm -f "$tmp"
        err "Ошибка в синтаксисе nftables! Изменения отменены."
        return 1
    fi

    install -d -m 755 /var/backups
    stamp="$(date +%Y%m%d%H%M%S)"
    NFT_MENU_BAK="/var/backups/nftables.conf.menu.${stamp}"
    cp -a "$NFT_CONF" "$NFT_MENU_BAK"
    install -m 644 -o root -g root "$tmp" "$NFT_CONF"
    rm -f "$tmp"

    if ! nft -f "$NFT_CONF"; then
        err "Не удалось применить правила. Возвращаю предыдущую версию."
        cp -a "$NFT_MENU_BAK" "$NFT_CONF"
        nft -f "$NFT_CONF" || true
        return 1
    fi
    return 0
}

sync_fail2ban_port() {
    local port="$1" jl="/etc/fail2ban/jail.local"
    [[ -f "$jl" ]] || return 0
    sed -i -E "/^\[sshd\]/,/^\[/ s/^port[[:space:]]*=.*/port = ${port}/" "$jl"
    if systemctl is-active --quiet fail2ban; then
        systemctl restart fail2ban || warn "Не удалось перезапустить fail2ban. Проверьте: fail2ban-client -t"
    fi
    return 0
}

show_status() {
    echo -e "\n${BOLD}Текущее состояние:${NC}"
    echo -e "• Пользователь SSH:      ${CYAN}$(conf_get SSH_USER)${NC}"
    echo -e "• Порт SSH (tcp):        ${CYAN}$(conf_get SSH_PORT)${NC}"
    echo -e "• VPN-порты (udp):       ${CYAN}$(conf_get VPN_UDP_PORTS)${NC}"
    echo -e "• Доп. TCP-порты:        ${CYAN}$(conf_get EXTRA_TCP_PORTS)${NC}"
    echo -e "• Настроено:             ${CYAN}$(conf_get CONFIGURED_AT)${NC}"
}

_ssh_port_rollback() {
    local bak="$1" old="$2" udp="$3" extras="$4"
    warn "Откат изменений порта SSH..."
    cp -a "$bak" "$SSHD_DROPIN"
    nft_commit "$old" "$udp" "$extras" || warn "Не удалось вернуть правило файервола для порта ${old}!"
    systemctl restart ssh.service || true
}

menu_change_ssh_port() {
    title "СМЕНА ПОРТА SSH"
    local cur udp extras new="" input attempt stamp bak listening eff

    cur="$(conf_get SSH_PORT)"
    udp="$(conf_get VPN_UDP_PORTS)"
    extras="$(conf_get EXTRA_TCP_PORTS)"
    valid_port "$cur" || { err "В $CONFIG_MARKER некорректный SSH_PORT."; return 1; }
    [[ -f "$SSHD_DROPIN" ]] || { err "Не найден $SSHD_DROPIN."; return 1; }
    info "Текущий порт SSH: ${cur}"

    for attempt in 1 2 3; do
        ask input "Введите новый порт SSH (1-65535) [Enter — отмена]: "
        input="$(trim "$input")"
        if [[ -z "$input" ]]; then
            info "Отменено."
            return 0
        fi
        if ! valid_port "$input"; then
            err "Введите корректное число от 1 до 65535 (попытка ${attempt}/3)."
            continue
        fi
        input=$((10#$input))
        if [[ "$input" == "$cur" ]]; then
            info "Порт не изменился."
            return 0
        fi
        if tcp_port_in_use "$input"; then
            err "TCP-порт ${input} уже занят другим процессом (попытка ${attempt}/3)."
            continue
        fi
        if list_has "$extras" "$input"; then
            err "Порт ${input}/tcp уже используется как дополнительный порт файервола. Сначала удалите его (пункт 3)."
            continue
        fi
        new="$input"
        break
    done
    [[ -n "$new" ]] || { err "Не удалось получить корректный порт."; return 1; }

    warn "Убедитесь, что порт ${new}/tcp не блокируется файерволом хостинг-провайдера."
    warn "Текущая сессия не оборвётся, но новые подключения пойдут только на порт ${new}."
    confirm "Сменить порт SSH ${cur} → ${new}? (y/N): " || { info "Отменено."; return 0; }

    stamp="$(date +%Y%m%d%H%M%S)"
    install -d -m 755 /var/backups
    bak="/var/backups/00-amnezia-hardening.conf.${stamp}"
    cp -a "$SSHD_DROPIN" "$bak"

    sed -i -E "s/^Port[[:space:]]+.*/Port ${new}/" "$SSHD_DROPIN"
    if ! grep -qx "Port ${new}" "$SSHD_DROPIN"; then
        cp -a "$bak" "$SSHD_DROPIN"
        err "Не удалось обновить строку Port в $SSHD_DROPIN."
        return 1
    fi

    if ! sshd -t; then
        cp -a "$bak" "$SSHD_DROPIN"
        err "Ошибка в конфигурации SSH! Файл возвращён."
        return 1
    fi
    eff="$(sshd -T | awk '/^port /{print $2}')"
    if [[ "$eff" != "$new" ]]; then
        cp -a "$bak" "$SSHD_DROPIN"
        err "Итоговый порт sshd (${eff}) не совпал с ожидаемым (${new}). Файл возвращён."
        return 1
    fi
    ok "Синтаксис sshd корректен."

    if ! nft_commit "$new" "$udp" "$extras"; then
        cp -a "$bak" "$SSHD_DROPIN"
        err "Файервол не обновлён. Порт SSH не менялся."
        return 1
    fi
    ok "Файервол: порт ${new}/tcp открыт, ${cur}/tcp закрыт для новых подключений."

    if ! systemctl restart ssh.service; then
        err "Не удалось перезапустить ssh.service."
        _ssh_port_rollback "$bak" "$cur" "$udp" "$extras"
        return 1
    fi

    listening=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if tcp_port_in_use "$new"; then
            listening=1
            break
        fi
        sleep 1
    done
    if [[ "$listening" -ne 1 ]] || ! systemctl is-active --quiet ssh.service; then
        err "SSH не слушает порт ${new} после перезапуска."
        _ssh_port_rollback "$bak" "$cur" "$udp" "$extras"
        return 1
    fi

    conf_set SSH_PORT "$new"
    sync_fail2ban_port "$new"
    ok "SSH успешно слушает порт ${new}."
    echo -e "${YELLOW}${BOLD}НЕ ЗАКРЫВАЙТЕ эту сессию.${NC} Проверьте вход из нового окна терминала:"
    echo -e "${CYAN}ssh -p ${new} -i /путь/до/ключа $(conf_get SSH_USER)@<IP_СЕРВЕРА>${NC}"
    echo "Не забудьте указать новый порт SSH в клиенте AmneziaVPN."
    return 0
}

PORT_SPEC_REGEX='^([0-9]{1,5})(/(tcp|udp))?$'

menu_add_port() {
    title "ДОБАВЛЕНИЕ ПОРТА В ФАЕРВОЛ"
    local input port proto ssh udp extras new_list

    ssh="$(conf_get SSH_PORT)"
    udp="$(conf_get VPN_UDP_PORTS)"
    extras="$(conf_get EXTRA_TCP_PORTS)"

    ask input "Порт и протокол (например, 8080/tcp или 51820/udp; без протокола = tcp) [Enter — отмена]: "
    input="$(trim "$input")"
    input="${input,,}"
    [[ -n "$input" ]] || { info "Отменено."; return 0; }

    if [[ ! "$input" =~ $PORT_SPEC_REGEX ]]; then
        err "Неверный формат. Ожидается, например, 8080/tcp."
        return 1
    fi
    port="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[3]:-tcp}"
    valid_port "$port" || { err "Порт должен быть числом от 1 до 65535."; return 1; }
    port=$((10#$port))

    if [[ "$proto" == "tcp" ]]; then
        if [[ "$port" == "$ssh" ]]; then
            err "Порт ${port}/tcp — это порт SSH, он уже открыт."
            return 1
        fi
        if list_has "$extras" "$port"; then
            err "Порт ${port}/tcp уже добавлен."
            return 1
        fi
    else
        if list_has "$udp" "$port"; then
            err "Порт ${port}/udp уже добавлен."
            return 1
        fi
    fi

    confirm "Открыть ${port}/${proto} во входящей цепочке? (y/N): " || { info "Отменено."; return 0; }

    if [[ "$proto" == "tcp" ]]; then
        new_list="$(list_add "$extras" "$port")"
        nft_commit "$ssh" "$udp" "$new_list" || return 1
        conf_set EXTRA_TCP_PORTS "$new_list"
    else
        new_list="$(list_add "$udp" "$port")"
        nft_commit "$ssh" "$new_list" "$extras" || return 1
        conf_set VPN_UDP_PORTS "$new_list"
    fi
    ok "Порт ${port}/${proto} открыт и сохранён в $CONFIG_MARKER."
    return 0
}

menu_remove_port() {
    title "УДАЛЕНИЕ ПОРТА ИЗ ФАЕРВОЛА"
    local input port proto="" ssh udp extras in_udp=0 in_tcp=0

    ssh="$(conf_get SSH_PORT)"
    udp="$(conf_get VPN_UDP_PORTS)"
    extras="$(conf_get EXTRA_TCP_PORTS)"
    info "VPN (udp): ${udp:-—}"
    info "Доп. (tcp): ${extras:-—}"
    info "SSH (tcp ${ssh}) удалить нельзя — для смены порта используйте пункт 1."

    ask input "Номер порта (или порт/протокол, например 8080/tcp) [Enter — отмена]: "
    input="$(trim "$input")"
    input="${input,,}"
    [[ -n "$input" ]] || { info "Отменено."; return 0; }

    if [[ ! "$input" =~ $PORT_SPEC_REGEX ]]; then
        err "Неверный формат."
        return 1
    fi
    port="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[3]:-}"
    valid_port "$port" || { err "Порт должен быть числом от 1 до 65535."; return 1; }
    port=$((10#$port))

    if [[ "$port" == "$ssh" && "$proto" != "udp" ]] && ! list_has "$extras" "$port"; then
        err "Это порт SSH. Его нельзя удалить, только изменить (пункт 1)."
        return 1
    fi

    if [[ "$proto" != "tcp" ]] && list_has "$udp" "$port"; then in_udp=1; fi
    if [[ "$proto" != "udp" ]] && list_has "$extras" "$port"; then in_tcp=1; fi

    if (( in_udp + in_tcp == 0 )); then
        err "Порт ${port} не найден в списках, управляемых скриптом."
        return 1
    fi
    if (( in_udp + in_tcp == 2 )); then
        err "Порт ${port} открыт и по tcp, и по udp. Укажите протокол: ${port}/tcp или ${port}/udp."
        return 1
    fi

    if (( in_udp == 1 )); then
        local new_udp
        new_udp="$(list_remove "$udp" "$port")"
        if [[ -z "$new_udp" ]]; then
            warn "Это ПОСЛЕДНИЙ UDP-порт VPN. После удаления VPN перестанет принимать подключения."
        fi
        confirm "Удалить ${port}/udp? (y/N): " || { info "Отменено."; return 0; }
        nft_commit "$ssh" "$new_udp" "$extras" || return 1
        conf_set VPN_UDP_PORTS "$new_udp"
        ok "Порт ${port}/udp удалён."
    else
        local new_extras
        new_extras="$(list_remove "$extras" "$port")"
        confirm "Удалить ${port}/tcp? (y/N): " || { info "Отменено."; return 0; }
        nft_commit "$ssh" "$udp" "$new_extras" || return 1
        conf_set EXTRA_TCP_PORTS "$new_extras"
        ok "Порт ${port}/tcp удалён."
    fi
    return 0
}

menu_reapply_nft() {
    title "ПЕРЕПРИМЕНЕНИЕ ПРАВИЛ NFTABLES"
    [[ -f "$NFT_CONF" ]] || { err "Файл $NFT_CONF не найден."; return 1; }
    if ! nft -c -f "$NFT_CONF"; then
        err "Ошибка в синтаксисе $NFT_CONF! Применение отменено."
        return 1
    fi
    if ! nft -f "$NFT_CONF"; then
        err "Не удалось применить $NFT_CONF."
        return 1
    fi
    if nft list table inet amnezia_filter >/dev/null 2>&1; then
        ok "Правила применены, таблица inet amnezia_filter активна."
    else
        warn "Файл применён, но таблица inet amnezia_filter не найдена. Проверьте $NFT_CONF."
    fi
    systemctl is-active --quiet nftables || warn "nftables.service не активен: правила не переживут перезагрузку. Выполните: systemctl enable --now nftables"
    return 0
}

menu_full_reset() {
    title "🚨 ПОЛНЫЙ СБРОС ЗАЩИТЫ"
    local ts_saved ssh_bak="" ssh_d_bak="" nft_conf_bak="" nft_dump="" stamp pre word eff

    ts_saved="$(conf_get BACKUP_TS)"
    if [[ -n "$ts_saved" && -f "/etc/ssh/sshd_config.bak.${ts_saved}" && -d "/etc/ssh/sshd_config.d.bak.${ts_saved}" ]]; then
        info "Использую резервные копии первоначальной настройки (метка ${ts_saved})."
    else
        ssh_bak="$(latest_backup '/etc/ssh/sshd_config.bak.*')"
        if [[ -z "$ssh_bak" ]]; then
            err "Резервные копии sshd_config не найдены. Автоматический сброс невозможен."
            return 1
        fi
        ts_saved="${ssh_bak##*.bak.}"
        warn "В $CONFIG_MARKER нет метки бэкапа. Использую самый свежий бэкап SSH (метка ${ts_saved})."
    fi
    ssh_bak="/etc/ssh/sshd_config.bak.${ts_saved}"
    ssh_d_bak="/etc/ssh/sshd_config.d.bak.${ts_saved}"
    if [[ ! -f "$ssh_bak" || ! -d "$ssh_d_bak" ]]; then
        err "Не найдена пара бэкапов SSH для метки ${ts_saved}."
        return 1
    fi

    if [[ -f "/var/backups/nftables.conf.bak.${ts_saved}" ]]; then
        nft_conf_bak="/var/backups/nftables.conf.bak.${ts_saved}"
    fi
    if [[ -f "/var/backups/nftables-backup-${ts_saved}.nft" ]]; then
        nft_dump="/var/backups/nftables-backup-${ts_saved}.nft"
    else
        nft_dump="$(latest_backup '/var/backups/nftables-backup-*.nft')"
    fi

    echo "Будет выполнено:"
    echo "  • Восстановлено: $ssh_bak → /etc/ssh/sshd_config"
    echo "  • Восстановлено: $ssh_d_bak → /etc/ssh/sshd_config.d"
    echo "  • Удалены таблицы inet amnezia_filter и ip amnezia_nat"
    if [[ -n "$nft_conf_bak" ]]; then
        echo "  • Восстановлено: $nft_conf_bak → $NFT_CONF"
    else
        echo "  • Исходный $NFT_CONF не найден — будет записан пустой файл (без правил)"
    fi
    [[ -z "$nft_dump" ]] || echo "  • Снимок правил для справки (не применяется): $nft_dump"
    echo "  • Удалён $CONFIG_MARKER"
    echo -e "${RED}${BOLD}После сброса вход по паролю и root-доступ могут снова оказаться разрешены, а файервол — отключён.${NC}"

    confirm "Вы уверены, что хотите сбросить защиту? (y/N): " || { info "Отменено."; return 0; }
    ask word "Для подтверждения введите слово RESET: "
    word="$(trim "$word")"
    if [[ "$word" != "RESET" ]]; then
        info "Подтверждение не получено. Ничего не изменено."
        return 0
    fi

    stamp="$(date +%Y%m%d%H%M%S)"
    pre="/var/backups/amnezia-reset-pre-${stamp}"
    install -d -m 700 "$pre"
    cp -a /etc/ssh/sshd_config "$pre/sshd_config"
    cp -a /etc/ssh/sshd_config.d "$pre/sshd_config.d"
    [[ ! -f "$NFT_CONF" ]] || cp -a "$NFT_CONF" "$pre/nftables.conf"
    ok "Снимок текущего состояния: ${pre}"

    nft delete table inet amnezia_filter 2>/dev/null || true
    nft delete table ip amnezia_nat 2>/dev/null || true
    if [[ -n "$nft_conf_bak" ]]; then
        install -m 644 -o root -g root "$nft_conf_bak" "$NFT_CONF"
    else
        printf '#!/usr/sbin/nft -f\n# Файл очищен сбросом amnezia-hardening (исходный конфиг не найден)\n' > "$NFT_CONF"
        chmod 644 "$NFT_CONF"
    fi
    if ! nft -c -f "$NFT_CONF" >/dev/null 2>&1; then
        warn "Восстановленный $NFT_CONF не проходит проверку синтаксиса. Проверьте вручную: nft -c -f $NFT_CONF"
    fi
    ok "Таблицы amnezia удалены, $NFT_CONF восстановлен (в живую не применялся, чтобы не затронуть правила Docker)."

    cp -a "$ssh_bak" /etc/ssh/sshd_config
    rm -rf /etc/ssh/sshd_config.d
    cp -a "$ssh_d_bak" /etc/ssh/sshd_config.d
    if ! sshd -t; then
        err "Восстановленная конфигурация SSH некорректна! Возвращаю состояние до сброса."
        cp -a "$pre/sshd_config" /etc/ssh/sshd_config
        rm -rf /etc/ssh/sshd_config.d
        cp -a "$pre/sshd_config.d" /etc/ssh/sshd_config.d
        return 1
    fi
    if systemctl restart ssh.service; then
        ok "SSH восстановлен и перезапущен."
    else
        warn "Не удалось перезапустить ssh.service. Проверьте: systemctl status ssh"
    fi

    eff="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    [[ -z "$eff" ]] || sync_fail2ban_port "$eff"

    rm -f "$CONFIG_MARKER"

    ok "Защита сброшена. Файл $CONFIG_MARKER удалён."
    echo -e "${YELLOW}Не затронуты: sysctl-настройки, fail2ban, unattended-upgrades, Docker, пользователь amnezia (если создавался).${NC}"
    echo -e "Для повторной настройки запустите скрипт заново — он выполнит первичную установку."
    exit 0
}

main_menu() {
    local choice c
    title "УПРАВЛЕНИЕ ЗАЩИТОЙ СЕРВЕРА AMNEZIA"
    ok "Обнаружена конфигурация ($CONFIG_MARKER). Первичная настройка пропущена."

    for c in nft sshd ss awk; do
        command -v "$c" >/dev/null 2>&1 || die "Не найдена команда '${c}'. Установите пакеты nftables, openssh-server, iproute2."
    done

    while true; do
        show_status
        echo
        echo "  1) Изменить порт SSH"
        echo "  2) Добавить порт в фаервол"
        echo "  3) Удалить порт из фаервола"
        echo "  4) Переприменить правила nftables"
        echo -e "  5) ${RED}🚨 ПОЛНЫЙ СБРОС ЗАЩИТЫ${NC}"
        echo "  6) Выйти"
        echo
        ask choice "Выберите пункт [1-6]: "
        choice="$(trim "$choice")"
        case "$choice" in
            1) menu_change_ssh_port || warn "Операция не выполнена." ;;
            2) menu_add_port        || warn "Операция не выполнена." ;;
            3) menu_remove_port     || warn "Операция не выполнена." ;;
            4) menu_reapply_nft     || warn "Операция не выполнена." ;;
            5) menu_full_reset      || warn "Сброс не выполнен." ;;
            6|q|Q) ok "Выход."; exit 0 ;;
            *) err "Неверный выбор: '${choice}'." ;;
        esac
    done
}

install_docker_inline() {
    title "УСТАНОВКА DOCKER"
    info "Обновление пакетов и установка зависимостей..."
    apt-get -qq -o DPkg::Lock::Timeout=120 update
    apt-get "${APT_OPTS[@]}" install curl ca-certificates gnupg lsb-release

    info "Добавление репозитория Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

    apt-get -qq -o DPkg::Lock::Timeout=120 update
    apt-get "${APT_OPTS[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    ok "Docker успешно установлен и запущен."
}

run_initial_setup() {

title "ПРОВЕРКА DOCKER"
if ! command -v docker >/dev/null 2>&1; then
    warn "Docker не установлен."
    if confirm "Установить Docker автоматически? (y/N): "; then
        install_docker_inline
    else
        die "Для работы скрипта необходим Docker. Завершение."
    fi
fi

if ! systemctl is-active --quiet docker; then
    warn "Служба Docker не запущена. Пытаюсь запустить..."
    systemctl enable --now docker || die "Не удалось запустить Docker."
fi
docker info >/dev/null 2>&1 || die "Docker установлен, но демон не отвечает."
ok "Docker установлен и запущен: $(docker --version)"

title "ПРОВЕРКА AMNEZIA VPN"
if ! AMNEZIA_CONTAINERS="$(docker ps -a --filter "name=amnezia" --format '{{.Names}}' 2>&1)"; then
    die "Не удалось получить список контейнеров Docker: ${AMNEZIA_CONTAINERS}"
fi
if [[ -z "$AMNEZIA_CONTAINERS" ]]; then
    err "Контейнеры AmneziaVPN не обнаружены!"
    echo -e "${YELLOW}Что делать:${NC}"
    echo "1. Откройте клиент AmneziaVPN на своём устройстве."
    echo "2. Добавьте этот сервер и установите нужные сервисы (AmneziaWG, Xray, OpenVPN и т.д.)."
    echo "3. Убедитесь, что команда 'docker ps' показывает контейнеры с именем amnezia-*."
    echo "4. Запустите этот скрипт снова."
    exit 1
fi
ok "Найдены контейнеры Amnezia: $(echo "$AMNEZIA_CONTAINERS" | tr '\n' ' ')"

title "ПОЛИТИКА ДОСТУПА"
echo -e "${YELLOW}ВАЖНО: Клиентское приложение AmneziaVPN по умолчанию требует root-доступ${NC}"
echo "для управления контейнерами и сетью на сервере."
echo "Создание отдельного пользователя может сломать автоматическое подключение клиента."
echo -e "${GREEN}Рекомендуемый путь: оставить root, но максимально его защитить (ключи, порт, fail2ban).${NC}\n"

SSH_USER="root"
ROOT_LOGIN="prohibit-password"
SSH_HOME="/root"

if confirm "Создать отдельного пользователя 'amnezia' вместо root? (y/N, НЕ РЕКОМЕНДУЕТСЯ): "; then
    SSH_USER="amnezia"
    ROOT_LOGIN="no"
    warn "Вы выбрали нестандартный путь. Вход по SSH под root будет полностью запрещён."
    if ! id amnezia >/dev/null 2>&1; then
        useradd -m -s /bin/bash amnezia
    fi
    usermod -aG docker amnezia
    SUDOERS_TMP="$(mktemp)"
    printf 'amnezia ALL=(ALL) NOPASSWD:ALL\n' > "$SUDOERS_TMP"
    visudo -cf "$SUDOERS_TMP" >/dev/null || die "Ошибка синтаксиса sudoers."
    install -m 440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/amnezia
    rm -f "$SUDOERS_TMP"
    SSH_HOME="$(getent passwd amnezia | cut -d: -f6)"
    ok "Пользователь 'amnezia' создан и добавлен в группу docker и sudoers."
else
    ok "Будет использован защищённый пользователь root (рекомендовано)."
fi

title "СИСТЕМНЫЕ НАСТРОЙКИ И ОБНОВЛЕНИЯ"
info "Установка необходимых пакетов..."
apt-get -qq -o DPkg::Lock::Timeout=120 update
apt-get "${APT_OPTS[@]}" install unattended-upgrades nftables fail2ban python3-systemd openssh-server iproute2

info "Настройка unattended-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52amnezia-unattended-upgrades <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades
ok "Автоматические обновления безопасности включены."

info "Применение харденинга ядра (sysctl)..."
cat > /etc/sysctl.d/99-amnezia-hardening.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.log_martians=1
EOF
if sysctl -q -p /etc/sysctl.d/99-amnezia-hardening.conf >/dev/null; then
    ok "Системные настройки применены."
else
    warn "Часть параметров sysctl применить не удалось (см. лог)."
fi

title "НАСТРОЙКА SSH"
echo -e "${YELLOW}ВАЖНО: убедитесь, что вставляете ПРАВИЛЬНЫЙ публичный SSH-ключ.${NC}"
echo "Если вы его потеряете, доступ к серверу будет утрачен без VNC/KVM консоли!"

KEY_REGEX='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$'
USER_SSH_KEY=""
for attempt in 1 2 3; do
    ask KEY_INPUT "Вставьте публичный SSH-ключ (одной строкой): "
    KEY_INPUT="$(trim "$KEY_INPUT")"
    if [[ -z "$KEY_INPUT" ]]; then
        err "Ключ не может быть пустым (попытка ${attempt}/3)."
        continue
    fi
    if [[ ! "$KEY_INPUT" =~ $KEY_REGEX ]]; then
        err "Это не похоже на публичный SSH-ключ (попытка ${attempt}/3). Нужна строка вида 'ssh-ed25519 AAAA... comment'."
        continue
    fi
    TMP_KEY="$(mktemp)"
    printf '%s\n' "$KEY_INPUT" > "$TMP_KEY"
    if KEY_FP="$(ssh-keygen -lf "$TMP_KEY" 2>/dev/null)"; then
        rm -f "$TMP_KEY"
        USER_SSH_KEY="$KEY_INPUT"
        ok "Ключ принят: ${KEY_FP}"
        break
    fi
    rm -f "$TMP_KEY"
    err "Ключ не прошёл проверку ssh-keygen (попытка ${attempt}/3)."
done
[[ -n "$USER_SSH_KEY" ]] || die "Не удалось получить корректный SSH-ключ. Изменения SSH не применялись."

install_authorized_key() {
    local user="$1" home="$2" group ssh_dir ak
    group="$(id -gn "$user")"
    ssh_dir="${home}/.ssh"
    ak="${ssh_dir}/authorized_keys"
    install -d -m 700 -o "$user" -g "$group" "$ssh_dir"
    if [[ -f "$ak" ]]; then
        cp -a "$ak" "${ak}.bak.${TS}"
    fi
    touch "$ak"
    if [[ -s "$ak" && -n "$(tail -c1 "$ak")" ]]; then
        printf '\n' >> "$ak"
    fi
    grep -qxF -- "$USER_SSH_KEY" "$ak" || printf '%s\n' "$USER_SSH_KEY" >> "$ak"
    chown "$user:$group" "$ak"
    chmod 600 "$ak"
}

install_authorized_key "$SSH_USER" "$SSH_HOME"
ok "SSH-ключ сохранён для пользователя ${SSH_USER}."

SSHD_EFFECTIVE="$(sshd -T 2>/dev/null || true)"
CURRENT_SSH_PORT="$(awk '/^port /{print $2; exit}' <<< "$SSHD_EFFECTIVE")"
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
info "Текущий порт SSH: ${CURRENT_SSH_PORT}"

SSH_PORT=""
for attempt in 1 2 3 4 5; do
    ask SSH_PORT_INPUT "Введите новый порт SSH (1-65535) [${CURRENT_SSH_PORT}]: "
    SSH_PORT_INPUT="$(trim "$SSH_PORT_INPUT")"
    CANDIDATE="${SSH_PORT_INPUT:-$CURRENT_SSH_PORT}"
    if ! valid_port "$CANDIDATE"; then
        err "Введите корректное число от 1 до 65535 (попытка ${attempt}/5)."
        continue
    fi
    CANDIDATE=$((10#$CANDIDATE))
    if [[ "$CANDIDATE" != "$CURRENT_SSH_PORT" ]] && tcp_port_in_use "$CANDIDATE"; then
        err "TCP-порт ${CANDIDATE} уже занят другим процессом (попытка ${attempt}/5)."
        continue
    fi
    SSH_PORT="$CANDIDATE"
    break
done
[[ -n "$SSH_PORT" ]] || die "Не удалось получить корректный порт SSH. Изменения SSH не применялись."

SSHD_BACKUP="/etc/ssh/sshd_config.bak.${TS}"
SSHD_D_BACKUP="/etc/ssh/sshd_config.d.bak.${TS}"
mkdir -p /etc/ssh/sshd_config.d
cp -a /etc/ssh/sshd_config "$SSHD_BACKUP"
cp -a /etc/ssh/sshd_config.d "$SSHD_D_BACKUP"
ok "Резервные копии: ${SSHD_BACKUP} и ${SSHD_D_BACKUP}"

restore_ssh() {
    warn "Откат конфигурации SSH из резервной копии..."
    cp -a "$SSHD_BACKUP" /etc/ssh/sshd_config
    rm -rf /etc/ssh/sshd_config.d
    cp -a "$SSHD_D_BACKUP" /etc/ssh/sshd_config.d
    systemctl restart ssh.service || true
}

if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" && "$f" != "$SSHD_DROPIN" ]] || continue
    sed -i -E 's/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|AuthenticationMethods|AllowUsers|AllowGroups|DenyUsers|DenyGroups)[[:space:]]+/#disabled-by-amnezia# &/I' "$f"
done

cat > "$SSHD_DROPIN" <<EOF
Port ${SSH_PORT}
PermitRootLogin ${ROOT_LOGIN}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${SSH_USER}
MaxAuthTries 3
LoginGraceTime 30
EOF
chmod 644 "$SSHD_DROPIN"

if ! sshd -t; then
    err "Ошибка в конфигурации SSH!"
    restore_ssh
    exit 1
fi

SSHD_EFFECTIVE="$(sshd -T)"
EFFECTIVE_PORTS="$(awk '/^port /{print $2}' <<< "$SSHD_EFFECTIVE")"
if [[ "$EFFECTIVE_PORTS" != "$SSH_PORT" ]] \
    || ! grep -qi '^passwordauthentication no$' <<< "$SSHD_EFFECTIVE" \
    || ! grep -qi '^pubkeyauthentication yes$' <<< "$SSHD_EFFECTIVE" \
    || ! grep -qi "^allowusers ${SSH_USER}\$" <<< "$SSHD_EFFECTIVE"; then
    err "Итоговая конфигурация sshd не соответствует ожидаемой."
    restore_ssh
    exit 1
fi
ok "Синтаксис и итоговая конфигурация sshd корректны."

if unit_exists ssh.socket; then
    systemctl disable --now ssh.socket 2>/dev/null || true
fi
systemctl enable ssh.service 2>/dev/null || true
systemctl restart ssh.service

SSH_LISTENING=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if tcp_port_in_use "$SSH_PORT"; then
        SSH_LISTENING=1
        break
    fi
    sleep 1
done
if [[ "$SSH_LISTENING" -ne 1 ]] || ! systemctl is-active --quiet ssh.service; then
    err "SSH не слушает порт ${SSH_PORT} после перезапуска."
    restore_ssh
    exit 1
fi
ok "SSH успешно слушает порт ${SSH_PORT}"
if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]] && tcp_port_in_use "$CURRENT_SSH_PORT"; then
    warn "Старый порт ${CURRENT_SSH_PORT} всё ещё занят. Проверьте: ss -tlnp"
fi

title "ОТКЛЮЧЕНИЕ ЛИШНИХ СЕРВИСОВ"
for svc in cups cups-browsed avahi-daemon ModemManager whoopsie kerneloops bluetooth snapd snapd.socket; do
    if unit_exists "${svc}.service" || unit_exists "${svc}"; then
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
    fi
done
ok "Неиспользуемые сервисы отключены."

title "НАСТРОЙКА FAIL2BAN"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = auto
banaction = nftables-multiport
banaction_allports = nftables-allports
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 5w
bantime.overalljails = true

[sshd]
enabled = true
backend = systemd
filter = sshd
port = ${SSH_PORT}
maxretry = 3
bantime = 2h

[recidive]
enabled = true
backend = auto
filter = recidive
logpath = /var/log/fail2ban.log
banaction = nftables-allports
protocol = all
bantime = 1w
findtime = 1d
maxretry = 3
EOF
if fail2ban-client -t >/dev/null 2>&1; then
    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "Fail2ban настроен с прогрессивным баном и jail recidive."
    else
        warn "Fail2ban запущен, но jail sshd не отвечает. Проверьте: fail2ban-client status"
    fi
else
    warn "Проверка конфигурации fail2ban не пройдена. Проверьте: fail2ban-client -t"
fi

title "НАСТРОЙКА ФАЙЕРВОЛА (NFTABLES)"

AUTO_PORTS="$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null \
    | tr ',' '\n' \
    | grep -oE '(0\.0\.0\.0|\[::\]|::):[0-9]+->[0-9]+/udp' \
    | sed -E 's/^.*:([0-9]+)->.*$/\1/' \
    | sort -nu \
    | paste -sd, - || true)"

VALID_PORTS=()
for attempt in 1 2 3 4 5; do
    if [[ -n "$AUTO_PORTS" ]]; then
        info "Автоматически обнаружены UDP-порты Amnezia: ${AUTO_PORTS}"
        ask PORTS_INPUT "Нажмите Enter для подтверждения или введите свои порты через запятую: "
    else
        warn "Не удалось автоопределить UDP-порты."
        ask PORTS_INPUT "Введите UDP-порты AmneziaVPN через запятую: "
    fi
    PORTS_INPUT="$(trim "$PORTS_INPUT")"
    PORTS_INPUT="${PORTS_INPUT:-$AUTO_PORTS}"
    PORTS_INPUT="${PORTS_INPUT//[[:space:]]/,}"

    IFS=',' read -ra PORTS_ARRAY <<< "$PORTS_INPUT"
    CANDIDATES=()
    INVALID=""
    for port in "${PORTS_ARRAY[@]:-}"; do
        [[ -n "$port" ]] || continue
        if valid_port "$port"; then
            CANDIDATES+=("$((10#$port))")
        else
            INVALID="${INVALID} ${port}"
        fi
    done

    if [[ -n "$INVALID" ]]; then
        err "Некорректные порты:${INVALID} (попытка ${attempt}/5)."
        continue
    fi
    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        err "Не указано ни одного порта (попытка ${attempt}/5)."
        continue
    fi

    mapfile -t CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | sort -nu)
    info "Будут открыты UDP-порты: ${CANDIDATES[*]}"
    if confirm "Всё верно? (y/N): "; then
        VALID_PORTS=("${CANDIDATES[@]}")
        break
    fi
    warn "Порты не подтверждены (попытка ${attempt}/5)."
done
[[ ${#VALID_PORTS[@]} -gt 0 ]] || die "Порты VPN не подтверждены. Файервол не изменялся."

UDP_SET="$(IFS=,; printf '%s' "${VALID_PORTS[*]}" | sed 's/,/, /g')"

EXT_IF="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
[[ -n "$EXT_IF" ]] || die "Не удалось определить внешний сетевой интерфейс."
info "Внешний интерфейс: ${EXT_IF}"

if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
    warn "Обнаружен активный ufw. Он будет отключён, чтобы не конфликтовать с nftables."
    ufw --force disable >/dev/null
fi

install -d -m 755 /var/backups
nft list ruleset > "/var/backups/nftables-backup-${TS}.nft" 2>/dev/null || true
chmod 600 "/var/backups/nftables-backup-${TS}.nft" 2>/dev/null || true
if [[ -f /etc/nftables.conf ]]; then
    cp -a /etc/nftables.conf "/var/backups/nftables.conf.bak.${TS}"
fi
ok "Резервные копии правил сохранены в /var/backups/"

NFT_NEW="$(mktemp)"
cat > "$NFT_NEW" <<EOF
table inet amnezia_filter
delete table inet amnezia_filter
table inet amnezia_filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        tcp dport ${SSH_PORT} accept
        udp dport { ${UDP_SET} } accept
        meta l4proto icmp limit rate 10/second accept
        limit rate 5/minute burst 5 packets log prefix "nft-input-drop: "
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "docker0" accept
        oifname "docker0" accept
        iifname "br-*" accept
        oifname "br-*" accept
        iifname "amn*" accept
        oifname "amn*" accept
        iifname "wg*" accept
        oifname "wg*" accept
        limit rate 5/minute burst 5 packets log prefix "nft-forward-drop: "
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
table ip amnezia_nat
delete table ip amnezia_nat
table ip amnezia_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${EXT_IF}" masquerade
    }
}
EOF

if ! nft -c -f "$NFT_NEW"; then
    rm -f "$NFT_NEW"
    die "Ошибка в синтаксисе nftables! Применение отменено."
fi
install -m 644 -o root -g root "$NFT_NEW" /etc/nftables.conf
rm -f "$NFT_NEW"

nft -f /etc/nftables.conf
systemctl enable --now nftables
ok "Правила nftables применены (политика drop, SSH ${SSH_PORT}/tcp, VPN ${VALID_PORTS[*]}/udp, masquerade)."

install -d -m 755 /etc/systemd/system/docker.service.d /etc/systemd/system/nftables.service.d
cat > /etc/systemd/system/docker.service.d/10-after-nftables.conf <<'EOF'
[Unit]
After=nftables.service
Wants=nftables.service
EOF
cat > /etc/systemd/system/nftables.service.d/10-before-docker.conf <<'EOF'
[Unit]
Before=docker.service
EOF
systemctl daemon-reload
if systemctl show docker.service -p After --value | grep -qw 'nftables.service'; then
    ok "nftables.service запускается строго до docker.service."
else
    warn "Не удалось подтвердить порядок запуска nftables -> docker. Проверьте: systemctl show docker.service -p After"
fi

cat > "$CONFIG_MARKER" <<EOF
SSH_USER="${SSH_USER}"
SSH_PORT="${SSH_PORT}"
VPN_UDP_PORTS="${VALID_PORTS[*]}"
EXTRA_TCP_PORTS=""
EXTERNAL_INTERFACE="${EXT_IF}"
BACKUP_TS="${TS}"
CONFIGURED_AT="$(date -Is)"
LAST_RUN="$(date +%s)"
EOF
chmod 600 "$CONFIG_MARKER"

title "✅ НАСТРОЙКА ЗАВЕРШЕНА"

EXTERNAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
EXTERNAL_IP="${EXTERNAL_IP:-ВАШ_IP}"

echo -e "${GREEN}${BOLD}Сервер успешно защищён!${NC}"
echo -e "• Пользователь: ${CYAN}${SSH_USER}${NC}"
echo -e "• SSH порт: ${CYAN}${SSH_PORT}${NC}"
echo -e "• VPN порты (UDP): ${CYAN}${VALID_PORTS[*]}${NC}"
echo -e "• Внешний IP: ${CYAN}${EXTERNAL_IP}${NC}"
echo -e "• Лог: ${CYAN}${LOGFILE}${NC}"

if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
    echo -e "\n${YELLOW}Порт SSH изменён на ${SSH_PORT}. Клиенту AmneziaVPN для управления сервером потребуется указать новый порт.${NC}"
fi

echo -e "\n${YELLOW}${BOLD}⚠️ ВАЖНО: НЕ ЗАКРЫВАЙТЕ ЭТОТ ТЕРМИНАЛ СРАЗУ! ⚠️${NC}"
echo "Откройте НОВОЕ окно терминала и проверьте подключение:"
echo -e "${CYAN}ssh -p ${SSH_PORT} -i /путь/до/вашего/приватного/ключа ${SSH_USER}@${EXTERNAL_IP}${NC}"
echo "Затем проверьте, что VPN-клиент подключается и трафик проходит."

echo -e "\n${RED}${BOLD}🚨 PANIC BUTTON (ЕСЛИ ВЫ ПОТЕРЯЛИ ДОСТУП): 🚨${NC}"
echo "1. Зайдите в веб-консоль (VNC/KVM) вашего хостинг-провайдера."
echo "2. Авторизуйтесь локально (логин/пароль пользователя; если пароль не задан — сбросьте его в панели хостинга)."
echo "3. Временно верните вход по паролю:"
echo -e "   ${CYAN}sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' ${SSHD_DROPIN} && systemctl restart ssh${NC}"
echo "4. Если закрыт доступ из-за файервола, временно уберите правила:"
echo -e "   ${CYAN}nft delete table inet amnezia_filter${NC}"
echo "5. Исправьте настройки и снова отключите пароли (повторный запуск скрипта)."
echo "Резервные копии: ${SSHD_BACKUP}, ${SSHD_D_BACKUP}, /var/backups/nftables-backup-${TS}.nft"

echo -e "\n${BOLD}Для управления сервером (порты, SSH, сброс) просто запустите этот скрипт снова — откроется меню.${NC}"
echo -e "${CYAN}curl -fsSLo /tmp/secure-amnezia.sh https://raw.githubusercontent.com/ApaTia13/secure-amnezia-server/refs/heads/main/secure-amnezia.sh && sudo bash /tmp/secure-amnezia.sh${NC}"
}

if [[ -f "$CONFIG_MARKER" ]]; then
    main_menu
else
    run_initial_setup
fi