#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=xterm

if command -v debconf-set-selections &>/dev/null; then
    echo "keyboard-configuration keyboard-configuration/xkb-keymap select us" | debconf-set-selections 2>/dev/null || true
    echo "keyboard-configuration keyboard-configuration/layout select USA" | debconf-set-selections 2>/dev/null || true
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
info()  { echo -e "${CYAN}${NC} $1"; }
title() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
success_banner() { echo -e "${GREEN}${BOLD}✅ $1${NC}"; }

CONFIG_MARKER="/root/.server-hardening.conf"

save_config() {
    cat > "$CONFIG_MARKER" <<EOF
# Сконфигурировано: $(date)
SSH_PORT="${SSH_PORT:-22}"
VALID_PORTS="${VALID_PORTS[*]:-}"
EXTRA_PORTS="${EXTRA_PORTS[*]:-}"
VPN_SUBNET="${VPN_SUBNET:-}"
LAST_RUN="$(date +%s)"
EOF
    chmod 600 "$CONFIG_MARKER"
}

load_config() {
    if [[ -f "$CONFIG_MARKER" ]]; then
        source "$CONFIG_MARKER"
        return 0
    fi
    return 1
}

show_amnezia_ports() {
    local containers
    containers=$(docker ps --filter "name=amnezia" --format "{{.Names}}\t{{.Ports}}" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        echo -e "\n${CYAN}📦 Найдены контейнеры AmneziaVPN:${NC}"
        echo "$containers" | while IFS=$'\t' read -r name ports; do
            local udp_ports
            udp_ports=$(echo "$ports" | grep -oP '0\.0\.0\.0:\K[0-9]+(?=->[0-9]+/udp)' || true)
            if [[ -n "$udp_ports" ]]; then
                echo "   • ${name}: ${udp_ports}/udp"
            fi
        done
    fi
}

# Функция для получения VPN подсети
get_vpn_subnet() {
    # Ищем IP-адрес на интерфейсах amn* или wg* и определяем подсеть
    local vpn_ip
    vpn_ip=$(ip -4 -o addr show | grep -E 'amn|wg' | awk '{print $4}' | head -1)
    
    if [[ -n "$vpn_ip" ]]; then
        # Преобразуем IP/маска в подсеть (например, 10.8.0.1/24 -> 10.8.0.0/24)
        local ip_part="${vpn_ip%/*}"
        local mask_part="${vpn_ip#*/}"
        
        if [[ "$mask_part" =~ ^[0-9]+$ ]]; then
            # CIDR маска
            local mask=$(( 0xFFFFFFFF << (32 - mask_part) & 0xFFFFFFFF ))
            local ip_int=$(( (10#${ip_part//./ })))
            # Упрощенно: берем первые 3 октета для /24
            if [[ "$mask_part" -eq 24 ]]; then
                echo "${ip_part%.*}.0/24"
            elif [[ "$mask_part" -eq 16 ]]; then
                echo "${ip_part%.*.*}.0.0/16"
            else
                echo "$vpn_ip"
            fi
        else
            echo "$vpn_ip"
        fi
    else
        # Fallback: стандартные VPN-подсети
        echo "10.8.0.0/24"
    fi
}

generate_nftables_config() {
    info "Генерация конфига nftables..."
    
    local ext_if
    ext_if=$(ip -4 route show default | awk '{print $5; exit}')
    ext_if=${ext_if:-eth0}
    
    # Получаем VPN подсеть
    local vpn_subnet="${VPN_SUBNET:-$(get_vpn_subnet)}"
    
    local tmp_nft
    tmp_nft=$(mktemp)
    
    cat > "$tmp_nft" <<EOF
#!/usr/sbin/nft -f
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        tcp dport ${SSH_PORT:-22} accept
EOF

    if [[ -n "${VALID_PORTS:-}" ]]; then
        for port in ${VALID_PORTS}; do
            echo "        udp dport $port accept" >> "$tmp_nft"
        done
    fi
    
    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        for port_entry in ${EXTRA_PORTS}; do
            local scope="${port_entry%%:*}"
            local rule_data="${port_entry#*:}"
            
            # Обратная совместимость
            if [[ "$scope" != "pub" && "$scope" != "vpn" ]]; then
                scope="pub"
                rule_data="$port_entry"
            fi
            
            local p_num="${rule_data%/*}"
            local p_proto="${rule_data#*/}"
            
            if [[ "$scope" == "vpn" ]]; then
                # ДВОЙНАЯ ЗАЩИТА: интерфейс VPN + IP из VPN-подсети
                echo "        iifname { \"amn*\", \"wg*\" } ip saddr $vpn_subnet $p_proto dport $p_num accept" >> "$tmp_nft"
            else
                # Публичный доступ
                echo "        $p_proto dport $p_num accept" >> "$tmp_nft"
            fi
        done
    fi
    
    cat >> "$tmp_nft" <<EOF
        ip protocol icmp accept
        limit rate 5/minute burst 5 packets log prefix "nft-input-drop: "
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "wg*" accept
        oifname "wg*" accept
        iifname "amn*" accept
        oifname "amn*" accept
        iifname "docker0" accept
        oifname "docker0" accept
        iifname "br-*" accept
        oifname "br-*" accept
        limit rate 5/minute burst 5 packets log prefix "nft-forward-drop: "
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$ext_if" masquerade
    }
}
EOF

    if ! nft -c -f "$tmp_nft"; then
        err "Ошибка в синтаксисе nftables! Отмена применения."
        rm -f "$tmp_nft"
        return 1
    fi
    
    mv "$tmp_nft" /etc/nftables.conf
    chmod 644 /etc/nftables.conf
    
    nft delete table inet filter 2>/dev/null || true
    nft delete table inet nat 2>/dev/null || true
    nft -f /etc/nftables.conf
    ok "Правила nftables успешно применены"
}

main_menu() {
    title "УПРАВЛЕНИЕ ЗАЩИТОЙ СЕРВЕРА"
    echo -e "${CYAN}Текущая конфигурация:${NC}"
    echo "  SSH порт: ${SSH_PORT:-22}"
    [[ -n "${VALID_PORTS:-}" ]] && echo "  VPN порты (UDP): ${VALID_PORTS}"
    [[ -n "${EXTRA_PORTS:-}" ]] && echo "  Доп. порты: ${EXTRA_PORTS}"
    [[ -n "${VPN_SUBNET:-}" ]] && echo "  VPN подсеть: ${VPN_SUBNET}"
    echo ""
    echo "1) Изменить SSH-ключ"
    echo "2) Изменить порт SSH"
    echo "3) Добавить/удалить порт в firewall"
    echo "4) Переприменить правила firewall"
    echo "5) Отключить защиту (полный сброс)"
    echo "6) Выйти"
    echo ""
    
    read -rp "Ваш выбор (1-6): " menu_choice
    case "$menu_choice" in
        1)
            read -rp "Вставьте новый публичный SSH-ключ: " new_key
            if echo "$new_key" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1; then
                echo "$new_key" > /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                ok "SSH-ключ обновлён"
                save_config
            else
                err "Невалидный ключ"
            fi
            ;;
        2)
            read -rp "Новый порт SSH: " new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
                grep -q "^Port " /etc/ssh/sshd_config || echo "Port $new_port" >> /etc/ssh/sshd_config
                if sshd -t; then
                    systemctl restart ssh
                    SSH_PORT=$new_port
                    save_config
                    ok "Порт SSH изменён на $new_port"
                else
                    err "Ошибка в конфиге SSH, порт не изменён"
                fi
            else
                err "Некорректный порт"
            fi
            ;;
        3)
            read -rp "Добавить (+) или удалить (-) порт? " action
            if [[ "$action" == "+" ]]; then
                read -rp "Введите порт и протокол (например, 8080/tcp): " new_p
                if [[ ! "$new_p" =~ ^[0-9]+/(tcp|udp)$ ]]; then
                    err "Формат должен быть как 8080/tcp или 53/udp"
                else
                    echo "Где должен быть доступен этот порт?"
                    echo "  1) В интернете (публичный доступ, как SSH)"
                    echo "  2) ТОЛЬКО через VPN-туннель (фильтр по интерфейсу + IP подсети)"
                    read -rp "Ваш выбор (1-2, по умолчанию 1): " scope_choice
                    
                    local scope="pub"
                    [[ "$scope_choice" == "2" ]] && scope="vpn"
                    
                    # Если VPN подсеть не задана, определяем её
                    if [[ "$scope" == "vpn" && -z "${VPN_SUBNET:-}" ]]; then
                        VPN_SUBNET=$(get_vpn_subnet)
                        info "Определена VPN подсеть: $VPN_SUBNET"
                    fi
                    
                    EXTRA_PORTS="${EXTRA_PORTS:-} ${scope}:${new_p}"
                    generate_nftables_config
                    save_config
                    
                    if [[ "$scope" == "vpn" ]]; then
                        ok "Порт $new_p добавлен (доступен ТОЛЬКО через VPN с IP из $VPN_SUBNET)"
                    else
                        ok "Порт $new_p добавлен (публичный доступ)"
                    fi
                fi
            elif [[ "$action" == "-" ]]; then
                if [[ -z "${EXTRA_PORTS:-}" ]]; then
                    info "Дополнительных портов нет"
                else
                    echo "Текущие дополнительные порты:"
                    local idx=1
                    for p in ${EXTRA_PORTS}; do
                        local display_p="${p#*:}"
                        local type_p="${p%%:*}"
                        local type_str="[ПУБЛИЧНЫЙ]"
                        [[ "$type_p" == "vpn" ]] && type_str="[ТОЛЬКО VPN]"
                        echo "  $idx) $display_p $type_str"
                        ((idx++)) || true
                    done
                    echo "  0) Отмена"
                    read -rp "Введите номер порта для удаления: " del_idx
                    
                    if [[ "$del_idx" -gt 0 ]] && [[ "$del_idx" -lt "$idx" ]]; then
                        local ports_arr=(${EXTRA_PORTS})
                        unset 'ports_arr[$((del_idx-1))]'
                        EXTRA_PORTS="${ports_arr[*]}"
                        generate_nftables_config
                        save_config
                        ok "Порт удалён"
                    else
                        info "Отмена"
                    fi
                fi
            fi
            ;;
        4)
            generate_nftables_config
            systemctl restart fail2ban 2>/dev/null || true
            ok "Правила переприменены"
            ;;
        5)
            read -rp "ВНИМАНИЕ! Это вернёт SSH на порт 22 с паролями и удалит firewall. Продолжить? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config
                sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
                sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                sed -i '/^AllowUsers/d' /etc/ssh/sshd_config
                systemctl restart ssh
                nft delete table inet filter 2>/dev/null || true
                nft delete table inet nat 2>/dev/null || true
                rm -f /etc/nftables.conf
                systemctl disable nftables 2>/dev/null || true
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
                sed -i '/disable_ipv6/d' /etc/sysctl.d/99-amnezia.conf 2>/dev/null || true
                rm -f /etc/systemd/system/docker.service.d/10-after-nftables.conf
                systemctl daemon-reload 2>/dev/null || true
                rm -f "$CONFIG_MARKER"
                success_banner "Защита отключена. Сервер сброшен."
            fi
            ;;
        6) exit 0 ;;
        *) err "Неверный выбор" ;;
    esac
}

# =====================================================
# НАЧАЛО ВЫПОЛНЕНИЯ
# =====================================================
if [[ $EUID -ne 0 ]]; then
    err "Скрипт должен выполняться от root (sudo)."
    exit 1
fi

LOGFILE="/var/log/server-hardening-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
info "Лог этого запуска сохраняется в: $LOGFILE"

title "ПРОВЕРКА НАЛИЧИЯ DOCKER И AMNEZIAVPN"
if ! command -v docker &>/dev/null; then err "Docker не установлен."; exit 1; fi
if ! systemctl is-active --quiet docker; then err "Docker не запущен."; exit 1; fi
ok "Docker установлен и запущен"

AMNEZIA_CONTAINERS=$(docker ps -a --filter "name=amnezia" --format "{{.Names}}" 2>/dev/null || true)
if [[ -z "$AMNEZIA_CONTAINERS" ]]; then err "Контейнеры AmneziaVPN не обнаружены."; exit 1; fi
ok "Найдены контейнеры AmneziaVPN: $(echo "$AMNEZIA_CONTAINERS" | tr '\n' ' ')"

if load_config; then
    info "Обнаружена предыдущая конфигурация. Открываю меню управления..."
    main_menu
    exit 0
fi

title "ОБНОВЛЕНИЕ СИСТЕМЫ"
apt-get update -qq || warn "apt update завершился с предупреждением"
apt-get upgrade -y -qq || warn "apt upgrade завершился с предупреждением"
apt-get install -y -qq openssh-server openssh-client nftables fail2ban iproute2 procps >/dev/null 2>&1 || warn "Некоторые пакеты не удалось установить"
ok "Система обновлена"

if command -v iptables &>/dev/null && iptables --version 2>/dev/null | grep -qi legacy; then
    warn "Docker использует iptables-legacy."
else
    ok "Docker использует nftables-бэкенд"
fi

title "1. НАСТРОЙКА SSH-КЛЮЧА"
mkdir -p /root/.ssh; chmod 700 /root/.ssh
echo -e "${YELLOW}ВАЖНО: Убедитесь, что вставляете правильный публичный ключ.${NC}\n"
while true; do
    read -rp "Вставьте публичный SSH-ключ: " ROOT_SSH_KEY
    [[ -z "$ROOT_SSH_KEY" ]] && { err "Ключ не может быть пустым"; continue; }
    tmp_key=$(mktemp)
    echo "$ROOT_SSH_KEY" > "$tmp_key"
    if ssh-keygen -lf "$tmp_key" >/dev/null 2>&1; then
        rm -f "$tmp_key"; break
    else
        err "Невалидный ключ."; rm -f "$tmp_key"
    fi
done
echo "$ROOT_SSH_KEY" > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
ok "SSH-ключ сохранён"

title "2. НАСТРОЙКА SSH-СЕРВЕРА"
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
current_ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}') || current_ssh_port=22
info "Текущий порт SSH: ${current_ssh_port:-22}"

while true; do
    read -rp "Новый порт SSH (по умолчанию 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then break; else err "Введите число от 1 до 65535"; fi
done

sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication " /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
sed -i '/^AllowUsers /d' /etc/ssh/sshd_config
echo "AllowUsers root" >> /etc/ssh/sshd_config

if ! sshd -t; then err "Ошибка в конфигурации SSH!"; exit 1; fi
systemctl stop ssh.socket 2>/dev/null || true; systemctl disable ssh.socket 2>/dev/null || true
systemctl restart ssh; sleep 2
if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then ok "SSH слушает порт $SSH_PORT"; else warn "Порт $SSH_PORT не обнаружен."; fi

title "3. IP-ФОРВАРДИНГ И IPv6"
sysctl -w net.ipv4.ip_forward=1 >/dev/null; echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-amnezia.conf 2>/dev/null || true
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null; sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.d/99-amnezia.conf 2>/dev/null || true
echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.d/99-amnezia.conf 2>/dev/null || true
ok "IP-форвардинг включён, IPv6 отключён"

# Определяем VPN подсеть для будущего использования
VPN_SUBNET=$(get_vpn_subnet)
info "Определена VPN подсеть: $VPN_SUBNET"

title "4. ОТКЛЮЧЕНИЕ СЕРВИСОВ"
for svc in cups avahi-daemon ModemManager whoopsie kerneloops bluetooth multipathd; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
ok "Лишние сервисы отключены"

title "5. FAIL2BAN"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = nftables-allports
bantime = 10m
findtime = 10m
maxretry = 3
[sshd]
enabled = true
port = $SSH_PORT
EOF
systemctl restart fail2ban; systemctl enable --quiet fail2ban
ok "fail2ban настроен"

title "6. ФАЙЕРВОЛ NFTABLES"
show_amnezia_ports; echo ""

while true; do
    read -rp "Введите UDP-порты AmneziaVPN через запятую: " AMNEZIA_PORTS_RAW
    IFS=',' read -ra AMNEZIA_PORTS <<< "$AMNEZIA_PORTS_RAW"
    VALID_PORTS=()
    for port in "${AMNEZIA_PORTS[@]}"; do
        port=$(echo "$port" | xargs)
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if [[ ! " ${VALID_PORTS[*]} " =~ " ${port} " ]]; then VALID_PORTS+=("$port"); fi
        else
            warn "Порт '$port' пропущен (некорректный)"
        fi
    done
    if [ ${#VALID_PORTS[@]} -eq 0 ]; then err "Не указано ни одного корректного порта. Попробуйте снова."; else break; fi
done

EXTRA_PORTS=()
nft list ruleset > "/etc/nftables-backup-$(date +%Y%m%d%H%M%S).nft" 2>/dev/null || true

generate_nftables_config
systemctl enable --quiet nftables

if systemctl list-unit-files | grep -q "^docker.service"; then
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/10-after-nftables.conf <<'EOF'
[Unit]
After=nftables.service
Wants=nftables.service
EOF
    systemctl daemon-reload; ok "Docker настроен на запуск после nftables"
fi
systemctl restart fail2ban 2>/dev/null || true

save_config
title "ГОТОВО"
success_banner "Скрипт безопасной настройки успешно завершён"
info "Порт SSH: $SSH_PORT"
info "Порты AmneziaVPN (UDP): ${VALID_PORTS[*]}"
info "VPN подсеть: $VPN_SUBNET"

external_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
echo -e "\n${YELLOW}️ ВАЖНО: Не закрывайте текущую сессию!${NC}"
echo -e "Проверьте подключение: ${CYAN}ssh -p $SSH_PORT -i /путь/до/ключа root@${external_ip:-<ваш-IP>}${NC}"
echo -e "\n${BOLD}Для изменения настроек в будущем просто запустите этот же скрипт снова.${NC}"