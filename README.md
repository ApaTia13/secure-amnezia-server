# 🔒 Secure Amnezia Server

Интерактивный скрипт для защиты сервера AmneziaVPN на Ubuntu 22.04 / 24.04: SSH только по ключу, файервол `nftables`, `fail2ban` и автообновления безопасности.

## 🚀 Быстрый старт

```bash
curl -fsSLo /tmp/secure-amnezia.sh https://raw.githubusercontent.com/ApaTia13/secure-amnezia-server/refs/heads/main/secure-amnezia.sh && sudo bash /tmp/secure-amnezia.sh
```

> Скрипт интерактивный и **не работает через** `curl | bash` (защита `require_tty`), поэтому сначала скачивается, затем запускается.

**Как это работает:**


1. Проверяет ОС, наличие Docker (предложит установить) и контейнеров `amnezia-*`.
2. Запрашивает публичный SSH-ключ и новый порт SSH, порты VPN определяет автоматически.
3. Применяет защиту и создаёт резервные копии конфигов в `/etc/ssh/` и `/var/backups/`.

> ⚠️ После завершения **не закрывайте текущую сессию**: проверьте вход по ключу из нового окна терминала и подключение VPN-клиента.

## 🛡️ Что делает скрипт

* **Docker** — проверяет наличие и при необходимости устанавливает из официального репозитория.
* **SSH** — вход только по ключу, пароли отключены, смена порта, `MaxAuthTries 3`; конфиг в `/etc/ssh/sshd_config.d/00-amnezia-hardening.conf` с автооткатом при ошибке.
* **nftables** — политика `drop`, открыты только SSH и UDP-порты Amnezia (определяются автоматически из Docker), NAT-masquerade, запуск строго до Docker.
* **fail2ban** — прогрессивный бан, рецидивисты (`recidive`) блокируются на неделю.
* **sysctl** — харденинг ядра, отключение IPv6, отключение лишних сервисов.
* **unattended-upgrades** — автоматические обновления безопасности.

## ⚙️ Управление

Повторный запуск той же команды открывает **интерактивное меню**:


1. Изменить порт SSH
2. Добавить порт в файервол
3. Удалить порт из файервола
4. Переприменить правила nftables
5. Полный сброс защиты (требует ввода `RESET`)

## 🚨 Troubleshooting

### Потерял доступ к SSH


1. Зайдите в VNC/KVM-консоль хостинга и авторизуйтесь локально.
2. Временно включите вход по паролю:

```bash
   sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/00-amnezia-hardening.conf
   systemctl restart ssh
```


3. Если доступ закрыт файерволом, временно удалите правила:

```bash
   nft delete table inet amnezia_filter
```


4. Войдите, исправьте настройки (например, через меню скрипта) и снова отключите пароли:

```bash
   sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/00-amnezia-hardening.conf
   systemctl restart ssh
```

### Amnezia не подключается


1. Убедитесь, что контейнеры запущены: `docker ps` (имена `amnezia-*`).
2. Проверьте, что UDP-порт VPN открыт: запустите скрипт и посмотрите «VPN-порты» в меню либо выполните `nft list table inet amnezia_filter`.
3. Если сменили порт SSH, укажите новый порт в клиенте AmneziaVPN.
4. При необходимости добавьте порт через меню (пункт 2) или примените правила заново (пункт 4).

## 📝 Примечания

* Перед изменениями создаются резервные копии: `/etc/ssh/sshd_config.bak.*`, `/etc/ssh/sshd_config.d.bak.*`, `/var/backups/nftables-*`.
* Журнал работы сохраняется в `/var/log/amnezia-hardening-*.log`.
* Клиент AmneziaVPN по умолчанию управляет сервером от `root`, поэтому скрипт по умолчанию оставляет `root` (только по ключу).
* Лицензия: [MIT](LICENSE).


