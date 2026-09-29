#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=xterm

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
info()  { echo -e "${CYAN}➜${NC} $1"; }
title() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }

CONFIG_MARKER="/root/.amnezia-hardening.conf"
LOGFILE="/var/log/amnezia-hardening-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1
info "Логирование сохранено в: $LOGFILE"

if [[ $EUID -ne 0 ]]; then
    err "Скрипт должен выполняться от root (используйте sudo)."
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        err "Скрипт предназначен строго для Ubuntu. Обнаружена: $ID ($PRETTY_NAME)"
        exit 1
    fi
    if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
        warn "Скрипт тестировался на Ubuntu 22.04/24.04. Ваша версия: $VERSION_ID. Продолжение на ваш страх и риск."
    fi
else
    err "Не удалось определить операционную систему."
    exit 1
fi

install_docker_inline() {
    title "УСТАНОВКА DOCKER"
    info "Обновление пакетов и установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq curl apt-transport-https ca-certificates software-properties-common
    
    info "Добавление репозитория Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    systemctl enable --now docker
    ok "Docker успешно установлен и запущен."
}

if ! command -v docker &>/dev/null || ! systemctl is-active --quiet docker; then
    warn "Docker не установлен или не запущен."
    read -rp "Установить Docker автоматически? (y/N): " INSTALL_DOCKER
    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
        install_docker_inline
    else
        err "Для работы скрипта необходим Docker. Завершение."
        exit 1
    fi
else
    ok "Docker установлен и запущен: $(docker --version)"
fi

title "ПРОВЕРКА AMNEZIA VPN"
AMNEZIA_CONTAINERS=$(docker ps -a --filter "name=amnezia" --format "{{.Names}}" 2>/dev/null || true)
if [[ -z "$AMNEZIA_CONTAINERS" ]]; then
    err "Контейнеры AmneziaVPN не обнаружены!"
    echo -e "${YELLOW}Сначала установите AmneziaVPN через официальный клиент или скрипт, затем запустите эту защиту.${NC}"
    exit 1
fi
ok "Найдены контейнеры Amnezia: $(echo "$AMNEZIA_CONTAINERS" | tr '\n' ' ')"

title "ПОЛИТИКА ДОСТУПА"
echo -e "${YELLOW}ВАЖНО: Клиентское приложение AmneziaVPN по умолчанию требует root-доступ${NC}"
echo "для управления контейнерами и сетью на сервере."
echo "Создание отдельного пользователя может сломать автоматическое подключение клиента."
echo -e "${GREEN}Рекомендуемый путь: Оставить root, но максимально его защитить (ключи, порт, fail2ban).${NC}\n"

read -rp "Создать отдельного пользователя 'amnezia' вместо root? (y/N, НЕ РЕКОМЕНДУЕТСЯ): " USE_NON_ROOT
SSH_USER="root"
if [[ "$USE_NON_ROOT" =~ ^[Yy]$ ]]; then
    SSH_USER="amnezia"
    warn "Вы выбрали нестандартный путь. Убедитесь, что ваш клиент Amnezia поддерживает подключение под обычным пользователем."
    useradd -m -s /bin/bash amnezia || true
    usermod -aG docker amnezia
    echo "amnezia ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/amnezia
    chmod 440 /etc/sudoers.d/amnezia
    ok "Пользователь 'amnezia' создан и добавлен в группу docker и sudoers."
else
    ok "Будет использован защищенный пользователь root (рекомендовано)."
fi

title "СИСТЕМНЫЕ НАСТРОЙКИ И ОБНОВЛЕНИЯ"
info "Установка и настройка unattended-upgrades (автоматические обновления безопасности)..."
apt-get install -y -qq unattended-upgrades
echo 'Unattended-Upgrade::Allowed-Origins:: "Ubuntu $(lsb_release -cs)-security";' > /etc/apt/apt.conf.d/51unattended-upgrades
systemctl enable --now unattended-upgrades

info "Применение харденинга ядра (sysctl)..."
cat > /etc/sysctl.d/99-amnezia-hardening.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
EOF
sysctl -p /etc/sysctl.d/99-amnezia-hardening.conf >/dev/null
ok "Системные настройки применены."

title "НАСТРОЙКА SSH"
mkdir -p /root/.ssh; chmod 700 /root/.ssh
if [[ "$SSH_USER" == "amnezia" ]]; then
    mkdir -p /home/amnezia/.ssh; chmod 700 /home/amnezia/.ssh; chown -R amnezia:amnezia /home/amnezia/.ssh
fi

echo -e "${YELLOW}ВАЖНО: Убедитесь, что вставляете ПРАВИЛЬНЫЙ публичный SSH-ключ.${NC}"
echo "Если вы его потеряете, доступ к серверу будет утрачен без VNC/KVM консоли!"
while true; do
    read -rp "Вставьте публичный SSH-ключ (одной строкой): " USER_SSH_KEY
    [[ -z "$USER_SSH_KEY" ]] && { err "Ключ не может быть пустым"; continue; }
    tmp_key=$(mktemp)
    echo "$USER_SSH_KEY" > "$tmp_key"
    if ssh-keygen -lf "$tmp_key" >/dev/null 2>&1; then
        rm -f "$tmp_key"; break
    else
        err "Невалидный формат ключа. Попробуйте снова."; rm -f "$tmp_key"
    fi
done

if [[ "$SSH_USER" == "root" ]]; then
    echo "$USER_SSH_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
else
    echo "$USER_SSH_KEY" > /home/amnezia/.ssh/authorized_keys
    chmod 600 /home/amnezia/.ssh/authorized_keys
    chown amnezia:amnezia /home/amnezia/.ssh/authorized_keys
fi
ok "SSH-ключ сохранен."

current_ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || echo "22")
info "Текущий порт SSH: ${current_ssh_port}"
while true; do
    read -rp "Введите новый порт SSH (1-65535, по умолчанию 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then 
        break
    else 
        err "Введите корректное число от 1 до 65535"
    fi
done

cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication " /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

if [[ "$SSH_USER" == "amnezia" ]]; then
    sed -i '/^AllowUsers /d' /etc/ssh/sshd_config
    echo "AllowUsers amnezia" >> /etc/ssh/sshd_config
else
    sed -i '/^AllowUsers /d' /etc/ssh/sshd_config
    echo "AllowUsers root" >> /etc/ssh/sshd_config
fi

if ! sshd -t; then err "Ошибка в конфигурации SSH!"; exit 1; fi
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl restart ssh
sleep 2
if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then 
    ok "SSH успешно слушает порт $SSH_PORT"
else 
    warn "Порт $SSH_PORT не обнаружен как LISTEN. Проверьте настройки."
fi

title "ОТКЛЮЧЕНИЕ ЛИШНИХ СЕРВИСОВ"
for svc in cups avahi-daemon ModemManager whoopsie kerneloops bluetooth multipathd snapd; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
ok "Неиспользуемые сервисы отключены."

title "НАСТРОЙКА FAIL2BAN"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = nftables-multiport
bantime = 1h
findtime = 1h
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 2h

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log*
banaction = nftables-multiport
bantime = 1w
findtime = 1d
maxretry = 3
EOF
systemctl enable --now fail2ban
ok "Fail2ban настроен с прогрессивным баном (рецидивисты банятся на неделю)."

title "НАСТРОЙКА ФАЙЕРВОЛА (NFTABLES)"

AUTO_PORTS=$(docker ps --filter "name=amnezia" --format "{{.Ports}}" | tr ',' '\n' | grep 'udp' | grep -oE '0\.0\.0\.0:[0-9]+' | cut -d':' -f2 | sort -u | tr '\n' ',' | sed 's/,$//')

if [[ -n "$AUTO_PORTS" ]]; then
    info "Автоматически обнаружены UDP-порты Amnezia: $AUTO_PORTS"
    read -rp "Подтвердите порты (нажмите Enter для использования найденных или введите свои): " AMNEZIA_PORTS_RAW
    AMNEZIA_PORTS_RAW=${AMNEZIA_PORTS_RAW:-$AUTO_PORTS}
else
    warn "Не удалось автоопределить порты. Введите их вручную."
    read -rp "Введите UDP-порты AmneziaVPN через запятую: " AMNEZIA_PORTS_RAW
fi

IFS=',' read -ra PORTS_ARRAY <<< "$AMNEZIA_PORTS_RAW"
VALID_PORTS=()
for port in "${PORTS_ARRAY[@]}"; do
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
    err "Не указано ни одного корректного порта. Завершение."
    exit 1
fi

info "Будут открыты UDP порты: ${VALID_PORTS[*]}"
read -rp "Все верно? (y/N): " CONFIRM_PORTS
if [[ ! "$CONFIRM_PORTS" =~ ^[Yy]$ ]]; then
    err "Отменено пользователем."
    exit 1
fi

nft list ruleset > "/etc/nftables-backup-$(date +%Y%m%d%H%M%S).nft" 2>/dev/null || true

mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
    echo '{}' > /etc/docker/daemon.json
fi

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/10-after-nftables.conf <<'EOF'
[Unit]
After=nftables.service
Wants=nftables.service
EOF
systemctl daemon-reload

EXT_IF=$(ip -4 route show default | awk '{print $5; exit}')
EXT_IF=${EXT_IF:-eth0}

cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        tcp dport ${SSH_PORT} accept
EOF

for port in "${VALID_PORTS[@]}"; do
    echo "        udp dport $port accept" >> /etc/nftables.conf
done

cat >> /etc/nftables.conf <<EOF
        ip protocol icmp accept
        limit rate 5/minute burst 5 packets log prefix "nft-input-drop: "
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname { "wg*", "amn*", "docker0", "br-*" } accept
        oifname { "wg*", "amn*", "docker0", "br-*" } accept
        limit rate 5/minute burst 5 packets log prefix "nft-forward-drop: "
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$EXT_IF" masquerade
    }
}
EOF

if ! nft -c -f /etc/nftables.conf; then
    err "Ошибка в синтаксисе nftables! Отмена применения."
    exit 1
fi

nft -f /etc/nftables.conf
systemctl enable --now nftables
ok "Правила nftables успешно применены."

title "✅ НАСТРОЙКА ЗАВЕРШЕНА"

EXTERNAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || echo "ВАШ_IP")

echo -e "${GREEN}${BOLD}Сервер успешно защищен!${NC}"
echo -e "• Пользователь: ${CYAN}$SSH_USER${NC}"
echo -e "• SSH Порт: ${CYAN}$SSH_PORT${NC}"
echo -e "• VPN Порты (UDP): ${CYAN}${VALID_PORTS[*]}${NC}"
echo -e "• Внешний IP: ${CYAN}$EXTERNAL_IP${NC}"

echo -e "\n${YELLOW}${BOLD}⚠️ ВАЖНО: НЕ ЗАКРЫВАЙТЕ ЭТОТ ТЕРМИНАЛ СРАЗУ! ⚠️${NC}"
echo "Откройте НОВОЕ окно терминала и проверьте подключение:"
echo -e "${CYAN}ssh -p $SSH_PORT -i /путь/до/вашего/приватного/ключа $SSH_USER@$EXTERNAL_IP${NC}"

echo -e "\n${RED}${BOLD}🚨 PANIC BUTTON (ЕСЛИ ВЫ ПОТЕРЯЛИ ДОСТУП): 🚨${NC}"
echo "1. Зайдите в веб-консоль (VNC/KVM) вашего хостинг-провайдера."
echo "2. Авторизуйтесь там (обычно логин/пароль от сервера)."
echo "3. Выполните команду для сброса защиты:"
echo -e "   ${CYAN}curl -sSL https://raw.githubusercontent.com/ApaTia13/secure-amnezia-server/refs/heads/main/secure-amnezia.sh | sudo bash${NC}"
echo "   (Затем выберите опцию полного сброса в меню, если она будет добавлена, или вручную верните Port 22 и PasswordAuthentication yes в /etc/ssh/sshd_config)."

echo -e "\n${BOLD}Для повторного запуска управления просто выполните этот скрипт снова.${NC}"

if [[ -f "$0" && "$0" != "bash" ]]; then
    read -rp "Удалить файл скрипта '$0' с сервера после выполнения? (y/N): " CLEANUP
    if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
        rm -f "$0"
        ok "Файл скрипта удален."
    fi
fi