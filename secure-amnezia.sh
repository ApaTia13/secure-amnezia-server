#!/bin/bash
set -euo pipefail      # Любая ошибка → немедленный выход

# Требуем root, иначе скрипт не сможет менять системные настройки
if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт от root (sudo)."
   exit 1
fi

echo "=== 1. Обновление системы ==="
apt update && apt upgrade -y

echo "=== 2. Настройка SSH-ключа для root ==="
# Создаём директорию .ssh для root с правильными правами
mkdir -p /root/.ssh
chmod 700 /root/.ssh
read -p "Вставьте публичный SSH-ключ для доступа к root: " ROOT_SSH_KEY
echo "$ROOT_SSH_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "SSH-ключ для root сохранён."

echo "=== 3. Настройка SSH ==="
SSH_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/ssh/sshd_config "$SSH_BACKUP"
echo "Резервная копия сохранена в $SSH_BACKUP"

read -p "Новый порт SSH (по умолчанию 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Некорректный порт, используется 22."
    SSH_PORT=22
fi

# Смена порта снижает количество автоматических атак (сканеры обычно ломятся на 22)
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

# Разрешаем root-доступ только по ключу (пароль запрещён)
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config

# Отключаем вход по паролю для всех (только ключи) — защита от брутфорса паролей
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

# Явно включаем аутентификацию по ключам (на случай если ранее было выключено)
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication " /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# Отключаем форвардинг X11 — редко нужно, увеличивает атакуемую поверхность
sed -i 's/^#*X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config
grep -q "^X11Forwarding " /etc/ssh/sshd_config || echo "X11Forwarding no" >> /etc/ssh/sshd_config

# Лимит попыток — после 3 неудач соединение рвётся, затрудняет перебор
sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 3/' /etc/ssh/sshd_config
grep -q "^MaxAuthTries " /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config

# Запрет пустых паролей — очевидно, но на всякий случай
sed -i 's/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
grep -q "^PermitEmptyPasswords " /etc/ssh/sshd_config || echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config

# Отключаем challenge-response — лишний вектор аутентификации
sed -i 's/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
grep -q "^ChallengeResponseAuthentication " /etc/ssh/sshd_config || echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config

# Проверяем конфиг перед перезапуском (защита от блокировки себя)
echo "Проверка конфигурации SSH..."
if ! sshd -t; then
    echo "Ошибка в конфигурации SSH! Откат к резервной копии."
    cp "$SSH_BACKUP" /etc/ssh/sshd_config
    exit 1
fi

# Определяем имя сервиса (в разных дистрибутивах может быть sshd или ssh)
if systemctl list-unit-files | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
elif systemctl list-unit-files | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
else
    echo "Не удалось найти SSH-сервис. Перезапустите вручную."
    exit 1
fi

systemctl restart "$SSH_SERVICE"
echo "SSH перезапущен (сервис $SSH_SERVICE): порт $SSH_PORT, root только по ключу."

echo "=== 4. IP-форвардинг ==="
CURRENT_FORWARD=$(sysctl -n net.ipv4.ip_forward)
if [ "$CURRENT_FORWARD" -eq 1 ]; then
    echo "IP-форвардинг уже включён."
else
    # Без форвардинга VPN-клиенты не смогут выходить в интернет через сервер
    read -p "IP-форвардинг выключен. Включить (нужно для выхода клиентов VPN в интернет)? [y/N]: " FW_CHOICE
    if [[ "$FW_CHOICE" =~ ^[Yy]$ ]]; then
        sysctl -w net.ipv4.ip_forward=1
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-amnezia.conf
        echo "IP-форвардинг включён."
    fi
fi

echo "=== 5. Отключение неиспользуемых сервисов ==="
# Чем меньше работающих сервисов, тем меньше потенциальных уязвимостей
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
        systemctl disable --now "$svc" 2>/dev/null || true
        echo "Сервис $svc отключён."
    fi
done

echo "=== 6. Установка и настройка fail2ban ==="
apt install -y fail2ban

# Автоматическая блокировка IP после 3 неудачных попыток за 10 минут
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
echo "fail2ban настроен для защиты SSH на порту $SSH_PORT."

echo "=== 7. Настройка файервола nftables ==="
# AmneziaVPN может слушать на нескольких UDP-портах одновременно (например, 443 и 8443)
read -p "Порты AmneziaVPN (UDP, через запятую, напр. 443,8443): " AMNEZIA_PORTS_RAW
IFS=',' read -ra AMNEZIA_PORTS <<< "$AMNEZIA_PORTS_RAW"
for port in "${AMNEZIA_PORTS[@]}"; do
    port=$(echo "$port" | xargs)
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Некорректный порт '$port'. Выход."
        exit 1
    fi
done

apt install -y nftables
# Сохраняем старые правила на случай, если новые заблокируют доступ
nft list ruleset > /etc/nftables-backup-$(date +%Y%m%d%H%M%S).nft 2>/dev/null || true

NFT_FILE="/etc/nftables.conf"
cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;   # Всё, что не разрешено, запрещено

        iif lo accept                     # loopback всегда доверяем
        ct state established,related accept   # Пускаем ответы на исходящие запросы

        tcp dport $SSH_PORT accept        # Нестандартный порт SSH (меньше сканеров)
EOF

# Добавляем все указанные UDP-порты для AmneziaVPN
for port in "${AMNEZIA_PORTS[@]}"; do
    echo "        udp dport $port accept" >> "$NFT_FILE"
done

cat >> "$NFT_FILE" <<EOF

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept         # ping полезен для диагностики
    }

    chain forward {
        type filter hook forward priority 0; policy drop;   # Маршрутизация запрещена по умолчанию
    }

    chain output {
        type filter hook output priority 0; policy accept;  # Исходящее разрешено
    }
}
EOF

nft -f "$NFT_FILE"
systemctl enable nftables
echo "Файервол применён. Открыты: порт SSH $SSH_PORT/TCP, Amnezia порты ${AMNEZIA_PORTS[*]}/UDP, ICMP."

echo "=== Готово ==="
echo "Доступ к серверу только по SSH-ключу для root на порту $SSH_PORT."
echo "⚠️ ВАЖНО: Прежде чем закрыть текущую сессию, откройте новое окно терминала и проверьте подключение:"
echo "  ssh -p $SSH_PORT -i путь_до_ключа root@<IP_сервера>"
echo "Если подключение не удаётся, откатите конфиг SSH:"
echo "  cp $SSH_BACKUP /etc/ssh/sshd_config && systemctl restart $SSH_SERVICE"
