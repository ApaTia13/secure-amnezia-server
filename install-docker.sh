#!/bin/bash
set -euo pipefail

# Цветное оформление
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

# Проверка root
if [[ $EUID -ne 0 ]]; then
    err "Скрипт должен выполняться от root (sudo)."
    exit 1
fi

title "1. ОБНОВЛЕНИЕ СИСТЕМЫ"
info "Обновление списка пакетов..."
apt update -y
info "Установка обновлений..."
apt upgrade -y
ok "Система обновлена"

title "2. УСТАНОВКА ЗАВИСИМОСТЕЙ"
info "Установка curl, apt-transport-https, ca-certificates, software-properties-common..."
apt install -y curl apt-transport-https ca-certificates software-properties-common
ok "Зависимости установлены"

title "3. УСТАНОВКА DOCKER"
info "Добавление официального репозитория Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

info "Обновление списка пакетов с репозиторием Docker..."
apt update -y

info "Установка Docker Engine, CLI и docker-compose-plugin..."
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
ok "Docker установлен"

title "4. ЗАПУСК И АВТОЗАГРУЗКА DOCKER"
systemctl enable --now docker
ok "Docker запущен и добавлен в автозагрузку"

title "5. ПРОВЕРКА УСТАНОВКИ"
if docker --version &>/dev/null; then
    ok "Docker version: $(docker --version)"
else
    err "Docker не установлен или не работает"
    exit 1
fi

if docker compose version &>/dev/null; then
    ok "Docker Compose version: $(docker compose version)"
else
    warn "Docker Compose plugin не найден (но это не критично)"
fi

title "ГОТОВО"
ok "Docker успешно установлен. Теперь можно устанавливать AmneziaVPN."
info "После установки AmneziaVPN запустите скрипт безопасной настройки:"
echo -e "  ${CYAN}bash secure-amnezia.sh${NC}"
