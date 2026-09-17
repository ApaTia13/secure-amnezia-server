#!/bin/bash
set -euo pipefail

# =====================================================
# Делаем все apt-операции неинтерактивными
# =====================================================
export DEBIAN_FRONTEND=noninteractive
export TERM=xterm

if command -v debconf-set-selections &>/dev/null; then
    echo "keyboard-configuration keyboard-configuration/xkb-keymap select us" | debconf-set-selections 2>/dev/null || true
    echo "keyboard-configuration keyboard-configuration/layout select USA" | debconf-set-selections 2>/dev/null || true
fi

# =====================================================
# Цветное оформление
# =====================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
info()  { echo -e "${CYAN}➜${NC} $1"; }
title() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
success_banner() { echo -e "${GREEN}${BOLD}✅ $1${NC}"; }

# =====================================================
# Маркер повторного запуска
# =====================================================
CONFIG_MARKER="/root/.server-hardening.conf"

save_config() {
    cat > "$CONFIG_MARKER" <<EOF
# Сконфигурировано: $(date)
SSH_PORT=$SSH_PORT
VPN_PORTS=${VALID_PORTS[*]}
EXTRA_PORTS=${EXTRA_PORTS[*]:-}
SSH_KEY_FINGERPRINT=$(ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null | head -1 | awk '{print $2}')
LAST_RUN=$(date +%s)
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

# =====================================================
# Проверка прав root
# =====================================================
if [[ $EUID -ne 0 ]]; then
    err "Скрипт должен выполняться от root (sudo)."
    exit 1
fi

# =====================================================
# Лог всего запуска
# =====================================================
LOGFILE="/var/log/server-hardening-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
info "Лог этого запуска сохраняется в: $LOGFILE"

# =====================================================
# Pre-flight проверка: Docker и AmneziaVPN
# =====================================================
title "ПРОВЕРКА НАЛИЧИЯ DOCKER И AMNEZIAVPN"

if ! command -v docker &>/dev/null; then
    err "Docker не установлен."
    err "Этот скрипт предназначен для серверов с AmneziaVPN в Docker."
    err "Установите Docker и AmneziaVPN перед запуском этого скрипта."
    exit 1
fi

if ! systemctl is-active --quiet docker; then
    err "Docker установлен, но не запущен."
    err "Запустите Docker: systemctl start docker"
    exit 1
fi

ok "Docker установлен и запущен"

AMNEZIA_CONTAINERS=$(docker ps -a --filter "name=amnezia" --format "{{.Names}}" 2>/dev/null || true)
if [[ -z "$AMNEZIA_CONTAINERS" ]]; then
    err "Контейнеры AmneziaVPN не обнаружены."
    err "Этот скрипт предназначен для настройки серверов с AmneziaVPN."
    err "Установите AmneziaVPN перед запуском этого скрипта."
    exit 1
fi

ok "Найдены контейнеры AmneziaVPN: $(echo $AMNEZIA_CONTAINERS | tr '\n' ' ')"

# =====================================================
# Обновление системы и установка зависимостей
# =====================================================
title "ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА ЗАВИСИМОСТЕЙ"

info "Обновление списков пакетов..."
apt-get update -qq || warn "apt update завершился с предупреждением"

info "Обновление установленных пакетов (это может занять несколько минут)..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || warn "apt upgrade завершился с предупреждением"

info "Установка необходимых пакетов для работы скрипта..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    openssh-server \
    openssh-client \
    nftables \
    fail2ban \
    at \
    iproute2 \
    procps \
    >/dev/null 2>&1 || warn "Некоторые пакеты не удалось установить"

ok "Система обновлена, зависимости установлены"

# =====================================================
# Предупреждения о конфликтующих файерволах
# =====================================================
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "Обнаружен активный ufw! Он может конфликтовать с правилами nftables из этого скрипта."
    warn "Рекомендуется отключить его перед продолжением: ufw disable"
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "Обнаружен активный firewalld! Он может конфликтовать/перезаписывать наши nftables-правила."
    warn "Рекомендуется: systemctl disable --now firewalld"
fi

if command -v iptables &>/dev/null && iptables --version 2>/dev/null | grep -qi legacy; then
    warn "Docker использует iptables-legacy, а не nftables-бэкенд."
    warn "Это значит, что наши nftables-правила НЕ влияют на Docker-трафик."
    warn "Рекомендуется переключить Docker на nftables-бэкенд:"
    warn "  update-alternatives --set iptables /usr/sbin/iptables-nft"
    warn "  systemctl restart docker"
else
    ok "Docker использует nftables-бэкенд (iptables-nft)"
fi

# =====================================================
# Функция: показать UDP-порты из контейнеров Amnezia
# =====================================================
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

# =====================================================
# Функция: показать текущие открытые порты
# =====================================================
show_current_ports() {
    echo -e "\n${CYAN} Текущая конфигурация:${NC}"
    echo "   SSH порт: ${SSH_PORT:-22}"
    if [[ -n "${VPN_PORTS:-}" ]]; then
        echo "   VPN порты (UDP): ${VPN_PORTS[*]}"
    fi
    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        echo "   Дополнительные порты: ${EXTRA_PORTS[*]}"
    fi
    echo ""
}

# =====================================================
# Функция: переприменить правила firewall
# =====================================================
reapply_firewall() {
    title "ПЕРЕПРИМЕНЕНИЕ ПРАВИЛ FIREWALL"
    
    if [[ ! -f /etc/nftables.conf ]]; then
        err "Файл /etc/nftables.conf не найден!"
        return 1
    fi
    
    info "Валидация конфига..."
    if ! nft -c -f /etc/nftables.conf; then
        err "Ошибка в конфиге nftables!"
        return 1
    fi
    
    info "Удаляем старые таблицы..."
    nft delete table inet filter 2>/dev/null || true
    nft delete table inet nat 2>/dev/null || true
    
    info "Применяем правила..."
    nft -f /etc/nftables.conf
    ok "Правила firewall переприменены"
    
    info "Перезапуск fail2ban..."
    systemctl restart fail2ban 2>/dev/null || true
    ok "fail2ban перезапущен"
    
    success_banner "Firewall перенастроен"
}

# =====================================================
# Функция: отключить защиту (полный rollback)
# =====================================================
disable_protection() {
    title "ОТКЛЮЧЕНИЕ ЗАЩИТЫ"
    
    warn "ВНИМАНИЕ! Это действие:"
    warn "  • Вернёт SSH на порт 22 с парольной аутентификацией"
    warn "  • Удалит все правила nftables"
    warn "  • Включит IPv6 обратно"
    warn "  • Отключит fail2ban"
    echo ""
    
    read -rp "Вы уверены? Это отключит всю защиту сервера! [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Отмена"
        return 0
    fi
    
    info "Возвращаем SSH конфиг..."
    if [[ -f /etc/ssh/sshd_config.bak.* ]]; then
        local backup
        backup=$(ls -t /etc/ssh/sshd_config.bak.* | head -1)
        cp "$backup" /etc/ssh/sshd_config
        ok "Восстановлен из $backup"
    else
        warn "Резервная копия SSH не найдена, настраиваем вручную"
        sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config
        sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i '/^AllowUsers/d' /etc/ssh/sshd_config
    fi
    systemctl restart ssh
    ok "SSH восстановлен"
    
    info "Удаляем правила nftables..."
    nft delete table inet filter 2>/dev/null || true
    nft delete table inet nat 2>/dev/null || true
    rm -f /etc/nftables.conf
    systemctl disable nftables 2>/dev/null || true
    ok "nftables отключён"
    
    info "Включаем IPv6..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    sed -i '/disable_ipv6/d' /etc/sysctl.d/99-amnezia.conf 2>/dev/null || true
    ok "IPv6 включён"
    
    info "Отключаем fail2ban..."
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    ok "fail2ban отключён"
    
    info "Удаляем drop-in Docker..."
    rm -f /etc/systemd/system/docker.service.d/10-after-nftables.conf
    systemctl daemon-reload 2>/dev/null || true
    ok "Drop-in Docker удалён"
    
    info "Удаляем маркер конфигурации..."
    rm -f "$CONFIG_MARKER"
    ok "Маркер удалён"
    
    success_banner "Защита полностью отключена. Сервер вернулся в исходное состояние."
    warn "Рекомендуется перезагрузить сервер: reboot"
}

# =====================================================
# Функция: изменить SSH-ключ
# =====================================================
change_ssh_key() {
    title "ИЗМЕНЕНИЕ SSH-КЛЮЧА"
    
    info "Текущий ключ (fingerprint):"
    ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null || warn "Ключ не найден"
    echo ""
    
    echo -e "${YELLOW}${BOLD}ВАЖНО:${NC} Убедитесь, что вставляете правильный публичный ключ."
    echo "Если ключ обрезан — доступ будет потерян."
    echo ""
    
    while true; do
        read -rp "Вставьте новый публичный SSH-ключ: " NEW_SSH_KEY
        if [[ -z "$NEW_SSH_KEY" ]]; then
            err "Ключ не может быть пустым"
            continue
        fi
        TMP_KEY_FILE=$(mktemp)
        echo "$NEW_SSH_KEY" > "$TMP_KEY_FILE"
        if ssh-keygen -lf "$TMP_KEY_FILE" >/dev/null 2>&1; then
            rm -f "$TMP_KEY_FILE"
            break
        else
            err "Невалидный ключ. Проверьте, не обрезался ли он."
            rm -f "$TMP_KEY_FILE"
        fi
    done
    
    # Заменяем ключ полностью
    echo "$NEW_SSH_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    ok "SSH-ключ заменён"
    
    # Обновляем fingerprint в маркере
    if load_config; then
        save_config
    fi
    
    success_banner "SSH-ключ обновлён"
}

# =====================================================
# Функция: изменить порт SSH
# =====================================================
change_ssh_port() {
    title "ИЗМЕНЕНИЕ ПОРТА SSH"
    
    info "Текущий порт SSH: ${SSH_PORT:-22}"
    echo ""
    
    while true; do
        read -rp "Новый порт SSH (по умолчанию 22): " NEW_SSH_PORT
        NEW_SSH_PORT=${NEW_SSH_PORT:-22}
        if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
            break
        else
            err "Введите число от 1 до 65535"
        fi
    done
    
    if [[ "$NEW_SSH_PORT" != "${SSH_PORT:-22}" ]]; then
        info "Устанавливаем порт $NEW_SSH_PORT..."
        sed -i "s/^Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
        grep -q "^Port " /etc/ssh/sshd_config || echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config
        
        info "Проверка конфигурации..."
        if ! sshd -t; then
            err "Ошибка в конфигурации SSH!"
            return 1
        fi
        
        systemctl restart ssh
        sleep 2
        
        if ss -tlnH "sport = :$NEW_SSH_PORT" 2>/dev/null | grep -q LISTEN; then
            ok "SSH теперь слушает порт $NEW_SSH_PORT"
            SSH_PORT=$NEW_SSH_PORT
            save_config
            success_banner "Порт SSH изменён на $NEW_SSH_PORT"
        else
            warn "Порт $NEW_SSH_PORT не обнаружен. Проверьте: ss -tlnp | grep :$NEW_SSH_PORT"
        fi
    else
        info "Порт не изменился"
    fi
}

# =====================================================
# Функция: управление портами firewall
# =====================================================
manage_ports() {
    title "УПРАВЛЕНИЕ ПОРТАМИ FIREWALL"
    
    show_current_ports
    
    echo "Выберите действие:"
    echo "  1) Добавить порт"
    echo "  2) Удалить порт"
    echo "  3) Назад"
    echo ""
    
    read -rp "Ваш выбор: " PORT_ACTION
    
    case "$PORT_ACTION" in
        1)
            echo ""
            echo "Тип порта:"
            echo "  1) UDP (для VPN, игр)"
            echo "  2) TCP (для web-серверов, SSH)"
            echo ""
            read -rp "Выберите тип (1-2): " PORT_TYPE
            
            case "$PORT_TYPE" in
                1) PROTO="udp" ;;
                2) PROTO="tcp" ;;
                *) err "Неверный выбор"; return 1 ;;
            esac
            
            read -rp "Введите номер порта: " NEW_PORT
            
            if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
                err "Некорректный порт"
                return 1
            fi
            
            # Проверяем, не занят ли порт
            if ss -tlnH "sport = :$NEW_PORT" 2>/dev/null | grep -q LISTEN; then
                warn "Порт $NEW_PORT уже используется"
                read -rp "Всё равно добавить в firewall? [y/N]: " FORCE
                [[ "$FORCE" =~ ^[Yy]$ ]] || return 1
            fi
            
            # Добавляем в EXTRA_PORTS
            EXTRA_PORTS=(${EXTRA_PORTS[*]:-} "$NEW_PORT/$PROTO")
            
            # Пересобираем конфиг nftables
            generate_nftables_config
            
            save_config
            ok "Порт $NEW_PORT/$PROTO добавлен"
            success_banner "Правила firewall обновлены"
            ;;
        2)
            echo ""
            echo "Текущие дополнительные порты:"
            if [[ ${#EXTRA_PORTS[@]} -eq 0 ]]; then
                info "Нет дополнительных портов"
                return 0
            fi
            
            for i in "${!EXTRA_PORTS[@]}"; do
                echo "  $((i+1))) ${EXTRA_PORTS[$i]}"
            done
            echo "  0) Отмена"
            echo ""
            
            read -rp "Выберите порт для удаления: " DEL_PORT
            
            if [[ "$DEL_PORT" -gt 0 ]] && [[ "$DEL_PORT" -le ${#EXTRA_PORTS[@]} ]]; then
                unset 'EXTRA_PORTS[$((DEL_PORT-1))]'
                EXTRA_PORTS=("${EXTRA_PORTS[@]}")
                
                generate_nftables_config
                save_config
                ok "Порт удалён"
                success_banner "Правила firewall обновлены"
            else
                info "Отмена"
            fi
            ;;
        3)
            return 0
            ;;
        *)
            err "Неверный выбор"
            ;;
    esac
}

# =====================================================
# Функция: генерация конфига nftables
# =====================================================
generate_nftables_config() {
    info "Генерация конфига nftables..."
    
    EXT_IF=$(ip -4 route show default | awk '{print $5; exit}')
    if [[ -z "$EXT_IF" ]]; then
        EXT_IF="eth0"
    fi
    
    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" <<EOF
#!/usr/sbin/nft -f
# Сгенерировано: $(date)
# НЕ добавляйте "flush ruleset" — это сломает Docker!

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        tcp dport $SSH_PORT accept
EOF

    # Добавляем VPN порты (UDP)
    if [[ -n "${VPN_PORTS:-}" ]]; then
        for port in "${VPN_PORTS[@]}"; do
            echo "        udp dport $port accept" >> "$TMP_NFT"
        done
    fi
    
    # Добавляем дополнительные порты
    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        for port_entry in "${EXTRA_PORTS[@]}"; do
            local port_num="${port_entry%/*}"
            local port_proto="${port_entry#*/}"
            echo "        $port_proto dport $port_num accept" >> "$TMP_NFT"
        done
    fi
    
    cat >> "$TMP_NFT" <<EOF

        ip protocol icmp accept

        limit rate 5/minute log prefix "nft-input-drop: "
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

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

        limit rate 5/minute log prefix "nft-forward-drop: "
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "$EXT_IF" masquerade
    }
}
EOF

    if ! nft -c -f "$TMP_NFT"; then
        err "Ошибка в конфиге nftables!"
        rm -f "$TMP_NFT"
        return 1
    fi
    
    mv "$TMP_NFT" /etc/nftables.conf
    chmod 644 /etc/nftables.conf
    
    nft delete table inet filter 2>/dev/null || true
    nft delete table inet nat 2>/dev/null || true
    nft -f /etc/nftables.conf
    
    ok "Правила nftables применены"
}

# =====================================================
# Главное меню (для повторного запуска)
# =====================================================
main_menu() {
    title "УПРАВЛЕНИЕ ЗАЩИТОЙ СЕРВЕРА"
    
    show_current_ports
    
    echo "Выберите действие:"
    echo "  1) Изменить SSH-ключ"
    echo "  2) Изменить порт SSH"
    echo "  3) Управление портами firewall (добавить/удалить)"
    echo "  4) Переприменить правила firewall"
    echo "  5) Отключить защиту (полный rollback)"
    echo "  6) Выйти"
    echo ""
    
    read -rp "Ваш выбор (1-6): " MENU_CHOICE
    
    case "$MENU_CHOICE" in
        1) change_ssh_key ;;
        2) change_ssh_port ;;
        3) manage_ports ;;
        4) reapply_firewall ;;
        5) disable_protection ;;
        6) 
            info "Выход"
            exit 0
            ;;
        *)
            err "Неверный выбор"
            exit 1
            ;;
    esac
}

# =====================================================
# Проверка: скрипт уже запускался?
# =====================================================
if load_config; then
    info "Обнаружена предыдущая конфигурация (последний запуск: $(date -d @$LAST_RUN 2>/dev/null || echo 'неизвестно'))"
    main_menu
    exit 0
fi

# =====================================================
# ПЕРВЫЙ ЗАПУСК: полная настройка
# =====================================================

# =====================================================
# 1. Настройка SSH-ключа для root
# =====================================================
title "1. НАСТРОЙКА SSH-КЛЮЧА ДЛЯ ROOT"
mkdir -p /root/.ssh
chmod 700 /root/.ssh

echo -e "${YELLOW}${BOLD}ВАЖНО:${NC} Убедитесь, что вставляете правильный публичный ключ,"
echo -e "который соответствует приватному ключу на вашем компьютере."
echo -e "Если ключ обрезан при копировании — доступ будет потерян.\n"

while true; do
    read -rp "Вставьте публичный SSH-ключ (начинается с ssh-rsa, ssh-ed25519 или ecdsa-...): " ROOT_SSH_KEY
    if [[ -z "$ROOT_SSH_KEY" ]]; then
        err "Ключ не может быть пустым"
        continue
    fi
    TMP_KEY_FILE=$(mktemp)
    echo "$ROOT_SSH_KEY" > "$TMP_KEY_FILE"
    if ssh-keygen -lf "$TMP_KEY_FILE" >/dev/null 2>&1; then
        rm -f "$TMP_KEY_FILE"
        break
    else
        err "Это не похоже на валидный публичный SSH-ключ (проверено через ssh-keygen -l)."
        err "Проверьте, не обрезался ли ключ при копировании."
        rm -f "$TMP_KEY_FILE"
    fi
done

touch /root/.ssh/authorized_keys
if ! grep -qF "$ROOT_SSH_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$ROOT_SSH_KEY" >> /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys
ok "SSH-ключ сохранён в /root/.ssh/authorized_keys"

# =====================================================
# 2. Настройка SSH (порт, запрет пароля, отключение сокета)
# =====================================================
title "2. НАСТРОЙКА SSH-СЕРВЕРА"

SSH_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)-$$"
cp /etc/ssh/sshd_config "$SSH_BACKUP"
ok "Резервная копия конфига SSH: $SSH_BACKUP"

CURRENT_SSH_PORT=22
if command -v sshd &>/dev/null; then
    CURRENT_SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}') || true
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
fi
info "Текущий порт SSH: $CURRENT_SSH_PORT"

while true; do
    read -rp "Новый порт SSH (по умолчанию 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then
        break
    else
        err "Введите число от 1 до 65535"
    fi
done

if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]] && \
   ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
    warn "Порт $SSH_PORT занят другим сервисом:"
    ss -tlnpH "sport = :$SSH_PORT" 2>/dev/null || true
    read -rp "Продолжить и изменить конфиг SSH? (sshd не сможет стартовать) [y/N]: " FORCE_CHOICE
    if [[ ! "$FORCE_CHOICE" =~ ^[Yy]$ ]]; then
        err "Выход. Выберите другой порт."
        exit 1
    fi
fi

info "Устанавливаем порт $SSH_PORT..."
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

info "Разрешаем root только по ключу..."
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config

info "Отключаем аутентификацию по паролю..."
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

info "Включаем аутентификацию по ключам..."
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication " /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

info "Применяем дополнительные параметры безопасности..."
sed -i 's/^#*X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config
grep -q "^X11Forwarding " /etc/ssh/sshd_config || echo "X11Forwarding no" >> /etc/ssh/sshd_config

sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 3/' /etc/ssh/sshd_config
grep -q "^MaxAuthTries " /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config

sed -i 's/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
grep -q "^PermitEmptyPasswords " /etc/ssh/sshd_config || echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config

sed -i 's/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
grep -q "^ChallengeResponseAuthentication " /etc/ssh/sshd_config || echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config

SSH_VER=$(ssh -V 2>&1 | grep -oP 'OpenSSH_\K[0-9]+\.[0-9]+' || echo "0.0")
SSH_MAJOR=${SSH_VER%%.*}
SSH_MINOR=${SSH_VER##*.}
if [[ "$SSH_MAJOR" -gt 8 ]] || { [[ "$SSH_MAJOR" -eq 8 ]] && [[ "$SSH_MINOR" -ge 7 ]]; }; then
    sed -i 's/^#*KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
    grep -q "^KbdInteractiveAuthentication " /etc/ssh/sshd_config || echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config
    ok "Добавлена современная директива KbdInteractiveAuthentication (OpenSSH $SSH_VER)"
fi

info "Ограничиваем вход по SSH только пользователем root..."
sed -i '/^AllowUsers /d' /etc/ssh/sshd_config
echo "AllowUsers root" >> /etc/ssh/sshd_config

info "Проверка конфигурации SSH..."
if ! sshd -t; then
    err "Ошибка в конфигурации SSH! Откат к резервной копии."
    cp "$SSH_BACKUP" /etc/ssh/sshd_config
    exit 1
fi
ok "Конфигурация валидна"

info "Отключаем ssh.socket (если активен)..."
if systemctl is-active ssh.socket >/dev/null 2>&1; then
    systemctl stop ssh.socket
    systemctl disable ssh.socket
    ok "ssh.socket остановлен и отключён"
else
    ok "ssh.socket не активен, пропускаем"
fi

info "Перезапуск ssh.service..."
systemctl restart ssh
ok "SSH-сервис перезапущен"

sleep 2
if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
    ok "SSH теперь слушает порт $SSH_PORT"
else
    warn "Порт $SSH_PORT не обнаружен. Проверьте вручную: ss -tlnp | grep \":$SSH_PORT\""
fi

success_banner "SSH настроен: порт $SSH_PORT, root только по ключу, сокет отключён"

# =====================================================
# 3. IP-форвардинг (для VPN) + отключение IPv6
# =====================================================
title "3. НАСТРОЙКА IP-ФОРВАРДИНГА И ОТКЛЮЧЕНИЕ IPv6"

SYSCTL_CONF="/etc/sysctl.d/99-amnezia.conf"
SYSCTL_BACKUP=""
if [[ -f "$SYSCTL_CONF" ]]; then
    SYSCTL_BACKUP="/etc/sysctl.d/99-amnezia.conf.bak.$(date +%s)-$$"
    cp "$SYSCTL_CONF" "$SYSCTL_BACKUP"
    ok "Резервная копия $SYSCTL_CONF: $SYSCTL_BACKUP"
fi

CURRENT_FORWARD=$(sysctl -n net.ipv4.ip_forward)
if [ "$CURRENT_FORWARD" -eq 1 ]; then
    ok "IP-форвардинг (IPv4) уже включён"
else
    read -rp "Включить IP-форвардинг (нужен для выхода VPN-клиентов в интернет)? [y/N]: " FW_CHOICE
    if [[ "$FW_CHOICE" =~ ^[Yy]$ ]]; then
        sysctl -w net.ipv4.ip_forward=1
        touch "$SYSCTL_CONF"
        grep -q '^net\.ipv4\.ip_forward=1' "$SYSCTL_CONF" || \
            echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
        ok "IP-форвардинг включён и записан в $SYSCTL_CONF"
    else
        warn "IP-форвардинг не включён. Клиенты VPN не смогут выходить в интернет."
    fi
fi

IPV6_CURRENT=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
if [ "$IPV6_CURRENT" -eq 1 ]; then
    ok "IPv6 уже отключён"
else
    info "Отключаем IPv6 (не используется VPN-клиентами)..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
    touch "$SYSCTL_CONF"
    grep -q '^net\.ipv6\.conf\.all\.disable_ipv6=1' "$SYSCTL_CONF" || \
        echo "net.ipv6.conf.all.disable_ipv6=1" >> "$SYSCTL_CONF"
    grep -q '^net\.ipv6\.conf\.default\.disable_ipv6=1' "$SYSCTL_CONF" || \
        echo "net.ipv6.conf.default.disable_ipv6=1" >> "$SYSCTL_CONF"
    ok "IPv6 отключён и записан в $SYSCTL_CONF"
fi

# =====================================================
# 4. Отключение неиспользуемых сервисов
# =====================================================
title "4. ОТКЛЮЧЕНИЕ НЕИСПОЛЬЗУЕМЫХ СЕРВИСОВ"
SERVICES_TO_DISABLE=(
    cups cups-browsed
    avahi-daemon
    ModemManager
    whoopsie
    kerneloops
    bluetooth
    multipathd
)

for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
        if systemctl is-enabled "$svc" &>/dev/null; then
            systemctl disable --now "$svc" 2>/dev/null || true
            ok "Сервис $svc отключён"
        else
            info "Сервис $svc уже отключён"
        fi
    fi
done

# =====================================================
# 5. Настройка fail2ban
# =====================================================
title "5. НАСТРОЙКА FAIL2BAN"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = nftables-allports
bantime = 10m
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = nftables-allports
bantime = 1w
findtime = 1d
maxretry = 3
EOF

systemctl restart fail2ban
systemctl enable --quiet fail2ban
ok "fail2ban настроен (блокировка после 3 неудач на 10 минут, рецидивисты — на неделю)"

# =====================================================
# 6. Настройка файервола nftables (совместимо с Docker!)
# =====================================================
title "6. НАСТРОЙКА ФАЙЕРВОЛА NFTABLES"

show_amnezia_ports

echo ""
read -rp "Введите UDP-порты AmneziaVPN (через запятую, например 39127,42448): " AMNEZIA_PORTS_RAW
IFS=',' read -ra AMNEZIA_PORTS <<< "$AMNEZIA_PORTS_RAW"
VALID_PORTS=()
for port in "${AMNEZIA_PORTS[@]}"; do
    port=$(echo "$port" | xargs)
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        if [[ ! " ${VALID_PORTS[*]} " =~ " ${port} " ]]; then
            VALID_PORTS+=("$port")
        fi
    else
        warn "Порт '$port' пропущен (некорректный)"
    fi
done

if [ ${#VALID_PORTS[@]} -eq 0 ]; then
    err "Не указано ни одного корректного UDP-порта. Выход."
    exit 1
fi

# Инициализируем EXTRA_PORTS
EXTRA_PORTS=()

BACKUP_NFT="/etc/nftables-backup-$(date +%Y%m%d%H%M%S)-$$.nft"
nft list ruleset > "$BACKUP_NFT" 2>/dev/null || true
ok "Резервная копия текущего состояния nftables: $BACKUP_NFT"

generate_nftables_config

systemctl enable --quiet nftables
ok "Файервол nftables с NAT применён (таблицы Docker не затронуты)"

if systemctl list-unit-files | grep -q "^docker.service"; then
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/10-after-nftables.conf <<'EOF'
[Unit]
After=nftables.service
Wants=nftables.service
EOF
    systemctl daemon-reload
    ok "Добавлена зависимость docker.service от nftables.service (After=/Wants=)"

    if systemctl is-active --quiet docker; then
        DOCKER_TABLES_OK=0
        if nft list table ip nat &>/dev/null || nft list table ip6 nat &>/dev/null \
           || nft list table ip docker-bridges &>/dev/null || nft list table ip6 docker-bridges &>/dev/null \
           || nft list table inet docker-bridges &>/dev/null; then
            DOCKER_TABLES_OK=1
        fi
        if [[ "$DOCKER_TABLES_OK" -eq 1 ]]; then
            ok "Таблицы Docker на месте — перезапуск Docker не требуется"
        else
            warn "Таблицы Docker (NAT/filter) не обнаружены в nftables."
            read -rp "Перезапустить Docker, чтобы он восстановил свои сетевые правила? [y/N]: " DOCKER_RESTART_CHOICE
            if [[ "$DOCKER_RESTART_CHOICE" =~ ^[Yy]$ ]]; then
                systemctl restart docker
                ok "Docker перезапущен"
                sleep 1
            else
                warn "Docker не перезапущен. При необходимости выполните вручную: systemctl restart docker"
            fi
        fi
    fi
fi

systemctl restart fail2ban 2>/dev/null || true

# =====================================================
# 7. Защита от потери SSH-доступа (автооткат)
# =====================================================
title "7. ЗАЩИТА ОТ ПОТЕРИ ДОСТУПА"

if ! systemctl enable --now atd 2>&1; then
    warn "atd не удалось запустить — автооткат через 'at' не сработает"
fi

ROLLBACK_MIN=7
STAMP=$(date +%s)
ROLLBACK_MARK="/root/.setup_confirmed_${STAMP}"
ROLLBACK_SCRIPT="/root/.rollback_${STAMP}.sh"

cat > "$ROLLBACK_SCRIPT" <<EOF
#!/bin/bash
if [ ! -f "$ROLLBACK_MARK" ]; then
    {
        echo "\$(date): подтверждение не получено — откатываю SSH и firewall"

        cp "$SSH_BACKUP" /etc/ssh/sshd_config
        systemctl restart ssh
        systemctl enable --now ssh.socket 2>/dev/null || true

        nft delete table inet filter 2>/dev/null || true
        nft delete table inet nat 2>/dev/null || true

        if [ -n "$NFT_CONF_BACKUP" ] && [ -f "$NFT_CONF_BACKUP" ]; then
            cp "$NFT_CONF_BACKUP" /etc/nftables.conf
            echo "Восстановлен предыдущий /etc/nftables.conf из $NFT_CONF_BACKUP"
        else
            rm -f /etc/nftables.conf
            systemctl disable nftables 2>/dev/null || true
            echo "Предыдущего nftables.conf не было — файл удалён, nftables.service отключён"
        fi

        if [ -n "$SYSCTL_BACKUP" ] && [ -f "$SYSCTL_BACKUP" ]; then
            cp "$SYSCTL_BACKUP" "$SYSCTL_CONF"
            echo "Восстановлен предыдущий $SYSCTL_CONF из $SYSCTL_BACKUP"
        else
            rm -f "$SYSCTL_CONF"
            echo "Предыдущего $SYSCTL_CONF не было — файл удалён"
        fi

        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true

        rm -f /etc/systemd/system/docker.service.d/10-after-nftables.conf
        systemctl daemon-reload
        echo "Удалён drop-in Docker: /etc/systemd/system/docker.service.d/10-after-nftables.conf"

        wall "ВНИМАНИЕ: автооткат SSH/firewall. Подробности: /var/log/setup-rollback.log" 2>/dev/null || true
    } >> /var/log/setup-rollback.log 2>&1
fi
rm -f "$ROLLBACK_SCRIPT"
EOF
chmod +x "$ROLLBACK_SCRIPT"

if echo "/bin/bash $ROLLBACK_SCRIPT" | at now + ${ROLLBACK_MIN} minutes >/dev/null 2>&1; then
    ok "Автооткат запланирован через ${ROLLBACK_MIN} минут (если не подтвердите доступ)"
else
    warn "Не удалось запланировать автооткат через 'at'."
fi

# =====================================================
# Сохраняем конфигурацию
# =====================================================
save_config

# =====================================================
# Финальная информация
# =====================================================
title "ГОТОВО"
success_banner "Скрипт безопасной настройки успешно завершён"
echo ""
info "Доступ к серверу: только по SSH-ключу для root"
info "Порт SSH: $SSH_PORT"
info "Порты AmneziaVPN (UDP): ${VALID_PORTS[*]}"
info "IPv6 отключён (sysctl)"
echo ""

EXTERNAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
if [[ -z "$EXTERNAL_IP" ]]; then
    EXTERNAL_IP="<ваш-IP>"
fi

echo -e "${YELLOW}${BOLD}⚠️  ВАЖНО:${NC} Не закрывайте текущую сессию. Откройте НОВОЕ окно терминала и проверьте подключение:"
echo -e "  ${CYAN}ssh -p $SSH_PORT -i /путь/до/ключа root@$EXTERNAL_IP${NC}"
echo ""
echo -e "${BOLD}Если новое подключение работает${NC}, подтвердите это командой (иначе через ${ROLLBACK_MIN} минут произойдёт автоматический откат):"
echo -e "  ${GREEN}touch $ROLLBACK_MARK${NC}"
echo ""

echo -e "${BOLD}=== КОМАНДЫ РУЧНОГО ОТКАТА (если что-то пошло не так) ===${NC}"
echo ""
echo -e "${YELLOW}1. Вернуть прежний SSH-конфиг и перезапустить sshd:${NC}"
echo -e "   ${CYAN}cp $SSH_BACKUP /etc/ssh/sshd_config && systemctl restart ssh${NC}"
if systemctl list-unit-files 2>/dev/null | grep -q "^ssh.socket"; then
    echo -e "   ${CYAN}systemctl enable --now ssh.socket 2>/dev/null || true${NC}"
fi
echo ""
echo -e "${YELLOW}2. Снести наши таблицы nftables из памяти (Docker не трогаем):${NC}"
echo -e "   ${CYAN}nft delete table inet filter 2>/dev/null; nft delete table inet nat 2>/dev/null${NC}"
echo ""
echo -e "${YELLOW}3. Удалить наш /etc/nftables.conf и отключить nftables.service:${NC}"
echo -e "   ${CYAN}rm -f /etc/nftables.conf && systemctl disable nftables${NC}"
echo ""
echo -e "${YELLOW}4. Удалить drop-in Docker (если был создан):${NC}"
echo -e "   ${CYAN}rm -f /etc/systemd/system/docker.service.d/10-after-nftables.conf && systemctl daemon-reload${NC}"
echo ""

echo -e "${BOLD}=== ПРОВЕРКА ПОСЛЕ РЕБУТА ===${NC}"
info "После перезагрузки выполните:"
echo -e "  ${CYAN}systemctl status nftables docker${NC}"
echo -e "  ${CYAN}nft list table inet filter | head -20${NC}"
echo -e "  ${CYAN}nft list table ip nat | head -20${NC}"
echo -e "  ${CYAN}ss -tlnp | grep :$SSH_PORT${NC}"
echo ""

echo -e "${BOLD}=== ПОВТОРНЫЙ ЗАПУСК ===${NC}"
info "При повторном запуске скрипта будет показано меню управления:"
echo -e "  ${CYAN}bash $0${NC}"
echo ""
echo -e "${BOLD}=== ПОЛЕЗНЫЕ ПРОВЕРКИ ===${NC}"
info "Правила Docker целы:     nft list table ip nat"
info "Наши правила:            nft list table inet filter; nft list table inet nat"
info "Полный лог запуска:      $LOGFILE"
echo ""

warn "SSH-доступ ограничен пользователем root (AllowUsers root)."
echo ""
info "Рекомендуется перезагрузить сервер и убедиться, что VPN и Docker поднимаются штатно: reboot"