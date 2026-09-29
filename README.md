# 🔒 Secure Amnezia Server

Скрипт для защиты сервера **AmneziaVPN** на Ubuntu 22.04/24.04.


---

## 🚀 Запуск

```bash
curl -sSL https://raw.githubusercontent.com/ApaTia13/secure-amnezia-server/refs/heads/main/secure-amnezia.sh | sudo bash
```

Скрипт сам установит Docker (если нужно) и проверит наличие AmneziaVPN.


---

## 🛡️ Что делает

* SSH: вход только по ключу, новый порт, запрет паролей
* Файервол `nftables`: открыты только SSH и порты Amnezia (определяются автоматически)
* `fail2ban` с прогрессивным баном (рецидивисты — на неделю)
* Отключение IPv6, лишних сервисов, харденинг ядра
* Автообновления безопасности (`unattended-upgrades`)


---

## 🚨 Потерял доступ?


1. Зайдите в VNC/KVM-консоль хостинга.
2. Временно включите вход по паролю:

   ```javascript
   sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
   systemctl restart ssh
   ```
3. Войдите на тачку, исправьте настройки и снова отключите пароли.

   ```javascript
   sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
   systemctl restart ssh
   ```


---


