# 🔒 Secure Amnezia Server

Набор скриптов для безопасного развёртывания **AmneziaVPN** на сервере Ubuntu (22.04/24.04).

- `install-docker.sh` – установка Docker и зависимостей.
- `secure-amnezia.sh` – настройка безопасности после установки AmneziaVPN:
  - SSH-ключ для root (доступ только по ключу, смена порта)
  - Отключение сокет-активации systemd
  - IP-форвардинг и маскарадинг (NAT) для VPN-трафика
  - Файервол nftables (закрыто всё, кроме SSH и VPN-портов)
  - Fail2ban для защиты SSH от брутфорса
  - Отключение ненужных сервисов (принт, Bluetooth, snapd и др.)

## 🚀 Быстрый старт

### Шаг 1. Установка Docker

```bash
sudo bash -c 'command -v curl >/dev/null || (apt update && apt install -y curl); curl -sSL https://raw.githubusercontent.com/ApaTia13/secure-amnezia-server/refs/heads/main/install-docker.sh -o install-docker.sh && chmod +x install-docker.sh && ./install-docker.sh'
```

### Шаг 2. Установка AmneziaVPN

После установки Docker разверните AmneziaVPN любым удобным способом (официальный скрипт, Docker Compose, ручная настройка).

### Шаг 3. Защита сервера

⚠️ Внимание: скрипт запросит ваш публичный SSH-ключ и новый порт для SSH. Перед закрытием текущей сессии обязательно проверьте подключение в новом окне терминала!
```bash
sudo bash -c 'command -v curl >/dev/null || (apt update && apt install -y curl); curl -sSL https://raw.githubusercontent.com/ApaTia13/secure-amnezia-server/refs/heads/main/secure-amnezia.sh -o secure-amnezia.sh && chmod +x secure-amnezia.sh && ./secure-amnezia.sh'
```

### Примечания

- Скрипты тестировались на Ubuntu 22.04/24.04.
- После настройки SSH будет слушать выбранный вами порт, вход по паролю запрещён.
- Файервол открывает только указанные UDP-порты Amnezia и ваш порт SSH.
- Если что-то пошло не так – есть резервные копии конфигов в /etc/ssh/ и /etc/nftables-backup-*.
