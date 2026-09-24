#!/bin/bash
set -eu

echo "=== Запуск подготовки сервера  ==="

# 1. Проверка запущен ли скрипт от root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Необходимо запустить скрипт от root (например через sudo)."
  exit 1
fi

# 2. Отключаем любые диалоговые окна
export DEBIAN_FRONTEND=noninteractive
# способ для новых версий
# export NEEDRESTART_mode=a

# 3. Задаём переменные
NEW_USER="devops"
SSH_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExVNSnaBVBTlHGaqKjDybm/SvmHrEv6XVo/1ukIZsDU eviartyan@gmail.com"


echo "=== [1/6] Обновление системы и установка необходимых пакетов  ==="


# 1. Обновление и установка софта
# --force-confdef - примянеяет новые настройки, если они изменились и нет конфликтов
# --force-confold - говорит, если есть конфликт, пиши старый файл
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl \
  wget \
  git \
  htop \
  ufw \
  fail2ban \
  unattended-upgrades

# 2. Настройка часового пояса
timedatectl set-timezone UTC


echo "=== [2/6] Настройка нового пользователя и SSH-ключей  ==="


# 1. Создаём нового пользователя
if id "$NEW_USER" &>/dev/null; then
  echo "Пользователь $NEW_USER уже сущесвует, пропускаем создание."
else 
  echo "Создаём пользователя $NEW_USER..."
  useradd -m -s /bin/bash "$NEW_USER"
fi

# 2. Добавляем в sudo
usermod -aG sudo "$NEW_USER"

# 3. Настраиваем sudo без запроса пароля
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
chmod 0440 "/etc/sudoers.d/$NEW_USER"

# 4. Создаем папку .ssh и ставим права
mkdir -p "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"

# 5. Записываем pub key в файл authorized_keys
echo "$SSH_PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# 6. Передаем права на папку новому пользователю
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"


echo "=== [3/6] Защита SSH-сервера  ==="


# 1. Проверяем, что у нашего пользователя реально создан SSH ключ (проверка чтоб не заблокировать самого себя)
if [ ! -s "/home/$NEW_USER/.ssh/authorized_keys" ]; then
  echo "Ошибка: Файл authorized_keys пуст или отсутствует! Во избежение блокировки отключаюсь..."
  exit 1
fi

# 2. Создаем отдельный файл конфигурации с новыми настройками безопасности

cat <<EOF > /etc/ssh/sshd_config.d/99-hardening.conf
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no

# Дополнительная настройка запрещающая ввод из клавиатуры (доп слой безопасности)
KbdInteractiveAuthentication no
EOF

# 3. Проверяем синтаксис конфигов SSH перед перезапуском
  if sshd -t; then
    echo "Конфигурация правильная, перезапускаю службу..."
    systemctl reload ssh
else
    echo "ОШИБКА: Ошибка в конфиге SSH! Изменения не применены."
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
fi


echo "=== [4/6] Настройка Firewall ==="


# 1. Устанавливаем дефолтные политики
ufw default deny incoming
ufw default allow outgoing

# 2. Разрешаем необходимые порты
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# 3. Включаем фаервол в неинтерактивном режиме (чтоб скрипт не останавливался)
ufw --force enable


echo "=== [5/6] Настройка защиты от брутфорса (Fail2Ban) ==="


# 1. Создаём конфиг
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
banaction = ufw
maxretry = 3
findtime = 10m
bantime = 1h
EOF

# 2. Перезапускаем Fail2Ban 
systemctl restart fail2ban


echo "=== [6/6] Настройка автоматических обновлений безопасности ==="


# Включаем автоматическую установку пакетов безопасности
cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl restart unattended-upgrades


echo "=== Скрипт успешно выполнен! ==="
