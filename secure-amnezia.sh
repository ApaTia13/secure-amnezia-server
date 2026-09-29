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
if [[ -f "$CONFIG_MARKER" ]]; then
    warn "Обнаружена предыдущая конфигурация ($CONFIG_MARKER). Настройки будут применены заново."
fi

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
EXTERNAL_INTERFACE="${EXT_IF}"
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

echo -e "\n${BOLD}Для повторного запуска управления просто выполните этот скрипт снова.${NC}"