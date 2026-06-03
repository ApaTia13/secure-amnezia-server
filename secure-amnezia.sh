#!/bin/bash
set -euo pipefail

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
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
info()  { echo -e "${CYAN}➜${NC} $1"; }
title() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
success_banner() { echo -e "${GREEN}${BOLD}✅ $1${NC}"; }

# =====================================================
# Проверка прав root
# =====================================================
if [[ $EUID -ne 0 ]]; then
    err "Скрипт должен выполняться от root (sudo)."
    exit 1
fi

# =====================================================
# Функция: показать UDP-порты из контейнеров Amnezia
# =====================================================
show_amnezia_ports() {
    if command -v docker &>/dev/null && docker ps --format "table" &>/dev/null; then
        local containers=$(docker ps --filter "name=amnezia" --format "{{.Names}}\t{{.Ports}}" 2>/dev/null)
        if [[ -n "$containers" ]]; then
            echo -e "\n${CYAN}📦 Найдены контейнеры AmneziaVPN:${NC}"
            echo "$containers" | while IFS=$'\t' read -r name ports; do
                local udp_ports=$(echo "$ports" | grep -oP '0\.0\.0\.0:\K[0-9]+(?=->[0-9]+/udp)' || true)
                if [[ -n "$udp_ports" ]]; then
                    echo "   • ${name}: ${udp_ports}/udp"
                fi
            done
        else
            warn "Контейнеры AmneziaVPN не обнаружены. Убедитесь, что VPN установлена."
        fi
    else
        warn "Docker не установлен или недоступен. Установите Docker перед запуском этого скрипта."
    fi
}

# =====================================================
# 1. Настройка SSH-ключа для root
# =====================================================
title "1. НАСТРОЙКА SSH-КЛЮЧА ДЛЯ ROOT"
mkdir -p /root/.ssh
chmod 700 /root/.ssh

while true; do
    read -p "Вставьте публичный SSH-ключ (начинается с ssh-rsa, ssh-ed25519 или ecdsa-...): " ROOT_SSH_KEY
    if [[ -z "$ROOT_SSH_KEY" ]]; then
        err "Ключ не может быть пустым"
    elif [[ ! "$ROOT_SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp) ]]; then
        err "Неверный формат ключа. Он должен начинаться с ssh-rsa, ssh-ed25519 или ecdsa-..."
    else
        break
    fi
done

echo "$ROOT_SSH_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ok "SSH-ключ сохранён в /root/.ssh/authorized_keys"

# =====================================================
# 2. Настройка SSH (порт, запрет пароля, отключение сокета)
# =====================================================
title "2. НАСТРОЙКА SSH-СЕРВЕРА"

SSH_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/ssh/sshd_config "$SSH_BACKUP"
ok "Резервная копия конфига SSH: $SSH_BACKUP"

while true; do
    read -p "Новый порт SSH (по умолчанию 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then
        break
    else
        err "Введите число от 1 до 65535"
    fi
done

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
if ss -tlnp | grep -q ":$SSH_PORT"; then
    ok "SSH теперь слушает порт $SSH_PORT"
else
    warn "Порт $SSH_PORT не обнаружен. Проверьте вручную: ss -tlnp | grep $SSH_PORT"
fi

success_banner "SSH настроен: порт $SSH_PORT, root только по ключу, сокет отключён"

# =====================================================
# 3. IP-форвардинг (для VPN)
# =====================================================
title "3. НАСТРОЙКА IP-ФОРВАРДИНГА"
CURRENT_FORWARD=$(sysctl -n net.ipv4.ip_forward)
if [ "$CURRENT_FORWARD" -eq 1 ]; then
    ok "IP-форвардинг уже включён"
else
    read -p "Включить IP-форвардинг (нужен для выхода VPN-клиентов в интернет)? [y/N]: " FW_CHOICE
    if [[ "$FW_CHOICE" =~ ^[Yy]$ ]]; then
        sysctl -w net.ipv4.ip_forward=1
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-amnezia.conf
        ok "IP-форвардинг включён и записан в /etc/sysctl.d/99-amnezia.conf"
    else
        warn "IP-форвардинг не включён. Клиенты VPN не смогут выходить в интернет."
    fi
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
    snapd
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
# 5. Установка и настройка fail2ban
# =====================================================
title "5. УСТАНОВКА И НАСТРОЙКА FAIL2BAN"
info "Установка fail2ban..."
apt install -y fail2ban >/dev/null 2>&1

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
EOF

systemctl restart fail2ban
systemctl enable fail2ban --quiet
ok "fail2ban настроен (блокировка после 3 неудач на 10 минут)"

# =====================================================
# 6. Настройка файервола nftables
# =====================================================
title "6. НАСТРОЙКА ФАЙЕРВОЛА NFTABLES"

# Показать текущие порты Docker-контейнеров Amnezia
show_amnezia_ports

# Запрос портов AmneziaVPN
echo ""
read -p "Введите UDP-порты AmneziaVPN (через запятую, например 39127,42448): " AMNEZIA_PORTS_RAW
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

apt install -y nftables >/dev/null 2>&1

# Резервное копирование текущих правил nftables
BACKUP_NFT="/etc/nftables-backup-$(date +%Y%m%d%H%M%S).nft"
nft list ruleset > "$BACKUP_NFT" 2>/dev/null || true
ok "Резервная копия nftables: $BACKUP_NFT"

# Определяем внешний сетевой интерфейс
EXT_IF=$(ip route | grep default | awk '{print $5}')
if [[ -z "$EXT_IF" ]]; then
    warn "Не удалось определить внешний интерфейс, masquerade может не работать"
    EXT_IF="eth0"  # fallback
else
    ok "Внешний интерфейс: $EXT_IF"
fi

# Генерация конфига nftables с NAT
NFT_FILE="/etc/nftables.conf"
cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept

        tcp dport $SSH_PORT accept
EOF

for port in "${VALID_PORTS[@]}"; do
    echo "        udp dport $port accept" >> "$NFT_FILE"
done

cat >> "$NFT_FILE" <<EOF

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # Разрешаем форвардинг для VPN-трафика (интерфейсы типа wg+)
        iifname "wg+" oifname "$EXT_IF" accept
        iifname "$EXT_IF" oifname "wg+" ct state related,established accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "$EXT_IF" masquerade
    }
}
EOF

nft -f "$NFT_FILE"
systemctl enable nftables --quiet
ok "Файервол nftables с NAT применён"

# =====================================================
# Финальная информация
# =====================================================
title "ГОТОВО"
success_banner "Скрипт безопасной настройки успешно завершён"
echo ""
info "Доступ к серверу: только по SSH-ключу для root"
info "Порт SSH: $SSH_PORT"
info "Порты AmneziaVPN (UDP): ${VALID_PORTS[*]}"
echo ""

# Важное предупреждение выводим сразу (без curl для скорости)
EXTERNAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
echo -e "${YELLOW}${BOLD}⚠️  ВАЖНО:${NC} Прежде чем закрыть текущую сессию, откройте НОВОЕ окно терминала и проверьте подключение:"
echo -e "  ${CYAN}ssh -p $SSH_PORT -i /путь/до/ключа root@$EXTERNAL_IP${NC}"
echo ""
echo -e "Если подключение не удаётся, откатите конфиг SSH:"
echo -e "  ${YELLOW}cp $SSH_BACKUP /etc/ssh/sshd_config && systemctl restart ssh${NC}"
echo -e "  ${YELLOW}systemctl enable --now ssh.socket   # если нужен сокет обратно${NC}"
echo ""
info "Рекомендуется перезагрузить сервер после завершения настройки: reboot"
