#!/bin/bash
set -euo pipefail      # Любая ошибка → немедленный выход

# Требуем root, иначе скрипт не сможет менять системные настройки
if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт от root (sudo)."
   exit 1
fi

echo "=== 1. Обновление системы ==="
apt update && apt upgrade -y

echo "=== 2. Создание пользователя ==="
read -p "Имя нового пользователя: " NEW_USER
if id "$NEW_USER" &>/dev/null; then
    echo "Пользователь $NEW_USER уже существует. Выход."
    exit 1
fi

# Пароль не должен светиться в истории терминала и на экране
read -s -p "Пароль для $NEW_USER: " USER_PASS
echo
read -s -p "Подтверждение пароля: " USER_PASS_CONFIRM
echo
if [[ "$USER_PASS" != "$USER_PASS_CONFIRM" ]]; then
    echo "Пароли не совпадают. Выход."
    exit 1
fi

# -m создаёт /home, -G sudo даёт админские привилегии
useradd -m -s /bin/bash -G sudo "$NEW_USER"
echo "$NEW_USER:$USER_PASS" | chpasswd

# SSH-ключ — вход без пароля по сети, безопаснее чем пароль
mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh
read -p "Вставьте публичный SSH-ключ для $NEW_USER: " SSH_KEY
echo "$SSH_KEY" > /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh

echo "Пользователь $NEW_USER создан (с sudo и SSH-ключом)."

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

# Запрет root по SSH — даже если подберут пароль, не смогут войти напрямую
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Отключаем вход по паролю (только ключи) — защита от брутфорса паролей
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

# Явно включаем ключи (на случай если ранее было выключено)
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication " /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# Отключаем форвардинг X11 — редко нужно, увеличивает атакуемую поверхность
sed -i 's/^#*X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config
grep -q "^X11Forwarding " /etc/ssh/sshd_config || echo "X11Forwarding no" >> /etc/ssh/sshd_config

# Лимит попыток — после 3 неудач соединение рвётся, затрудняет перебор
sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 3/' /etc/ssh/sshd_config
grep -q "^MaxAuthTries " /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config

# Отключаем пустые пароли — очевидно, но на всякий случай
sed -i 's/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
grep -q "^PermitEmptyPasswords " /etc/ssh/sshd_config || echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config

# Отключаем challenge-response — лишний вектор аутентификации
sed -i 's/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
grep -q "^ChallengeResponseAuthentication " /etc/ssh/sshd_config || echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config

# Двухфакторка для созданного пользователя: ключ И пароль.
# Даже если ключ украдут — нужен ещё пароль, и наоборот.
sed -i "/^Match User $NEW_USER/,/^Match/d" /etc/ssh/sshd_config
cat >> /etc/ssh/sshd_config <<EOF

Match User $NEW_USER
    PasswordAuthentication yes
    AuthenticationMethods publickey,password
EOF

systemctl restart sshd
echo "SSH перезапущен: порт $SSH_PORT, root-вход запрещён, для $NEW_USER обязательны ключ+пароль."

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
read -p "Порт AmneziaVPN (UDP), который уже используется: " AMNEZIA_PORT
if ! [[ "$AMNEZIA_PORT" =~ ^[0-9]+$ ]] || [ "$AMNEZIA_PORT" -lt 1 ] || [ "$AMNEZIA_PORT" -gt 65535 ]; then
    echo "Некорректный порт. Выход."
    exit 1
fi

apt install -y nftables
# Сохраняем старые правила на случай, если новые сломают доступ
nft list ruleset > /etc/nftables-backup-$(date +%Y%m%d%H%M%S).nft 2>/dev/null || true

NFT_FILE="/etc/nftables.conf"
cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;   # Всё, что не разрешено явно, запрещено

        iif lo accept                     # localhost всегда доверенный
        ct state established,related accept   # Разрешаем ответы на наши запросы

        tcp dport $SSH_PORT accept        # SSH с нестандартного порта
        udp dport $AMNEZIA_PORT accept    # Порт для AmneziaVPN

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept         # ping полезен для диагностики, но не опасен
    }

    chain forward {
        type filter hook forward priority 0; policy drop;   # По умолчанию маршрутизация запрещена
    }

    chain output {
        type filter hook output priority 0; policy accept;  # Исходящее разрешено всё (но можно усилить)
    }
}
EOF

nft -f "$NFT_FILE"
systemctl enable nftables
echo "Файервол применён. Открыты: порт SSH $SSH_PORT/TCP, Amnezia $AMNEZIA_PORT/UDP, ICMP."

echo "=== Готово ==="
echo "Пользователь $NEW_USER создан. Для SSH обязателен ключ + пароль."
echo "⚠️ ВАЖНО: Прежде чем закрыть текущую сессию, откройте новое окно терминала и проверьте подключение по SSH на порт $SSH_PORT."
echo "Если подключение не удаётся, откатите конфиг SSH командой:"
echo "  cp $SSH_BACKUP /etc/ssh/sshd_config && systemctl restart sshd"
