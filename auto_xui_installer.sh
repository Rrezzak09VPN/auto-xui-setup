#!/bin/bash

# Скрипт автоматической установки 3x-ui с перезагрузкой
# Версия: 1.0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

# Проверка root прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Функция для ожидания подключения пользователя после перезагрузки
wait_for_user_connection() {
    log "Ожидание подключения пользователя после перезагрузки..."
    log "Пожалуйста, подключитесь к серверу через SSH в течение 5 минут"
    
    # Создаем файл-маркер для отслеживания состояния
    echo "waiting" > /tmp/xui_install_state
    
    # Запускаем мониторинг в фоне
    (
        sleep 300  # Ждем 5 минут
        if [ -f /tmp/xui_install_state ]; then
            echo "timeout" > /tmp/xui_install_state
        fi
    ) &
    
    # Ждем подключения пользователя
    while [ -f /tmp/xui_install_state ] && [ "$(cat /tmp/xui_install_state)" = "waiting" ]; do
        sleep 5
    done
    
    if [ -f /tmp/xui_install_state ] && [ "$(cat /tmp/xui_install_state)" = "timeout" ]; then
        error "Время ожидания подключения пользователя истекло"
        rm -f /tmp/xui_install_state
        exit 1
    fi
    
    rm -f /tmp/xui_install_state
    success "Пользователь подключен, продолжаем установку..."
}

# Функция для проверки, является ли это продолжением после перезагрузки
is_continuation() {
    [ -f /tmp/xui_install_continuation ]
}

# Функция для обновления системы
update_system() {
    log "Обновление системы..."
    
    # Автоматизируем ответы на возможные вопросы
    export DEBIAN_FRONTEND=noninteractive
    
    # Обновляем списки пакетов
    apt-get update -y
    
    # Обновляем все пакеты с автоматическим подтверждением
    apt-get upgrade -y -o Dpkg::Options::="--force-confold"
    
    # Устанавливаем необходимые пакеты
    apt-get install -y curl wget sqlite3 python3 python3-pip openssl ufw net-tools tzdata
    
    # Устанавливаем bcrypt для работы с хэшами
    pip3 install bcrypt --break-system-packages
    
    success "Система обновлена"
}

# Функция для перезагрузки системы
reboot_system() {
    log "Создание скрипта продолжения установки..."
    
    # Создаем скрипт для продолжения после перезагрузки
    cat > /root/continue_xui_install.sh << 'CONTINUE_EOF'
#!/bin/bash
# Скрипт продолжения установки 3x-ui

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Помечаем, что это продолжение установки
echo "continuation" > /tmp/xui_install_continuation

# Запускаем основной скрипт установки
log "Продолжаем установку 3x-ui после перезагрузки..."

# Скачиваем и запускаем установку 3x-ui
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

if [ $? -eq 0 ]; then
    log "3x-ui успешно установлен"
    
    # Ждем немного, чтобы сервис запустился
    sleep 10
    
    # Настраиваем SSL и другие параметры
    log "Настройка SSL сертификатов и других параметров..."
    
    # Создаем директорию для SSL
    mkdir -p /etc/ssl/xui
    
    # Генерируем SSL сертификат на 10 лет
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/xui/secret.key \
        -out /etc/ssl/xui/cert.crt \
        -subj "/C=US/ST=State/L=City/O=X-UI-Panel/CN=$(hostname -I | awk '{print $1}')" \
        -addext "subjectAltName=DNS:$(hostname),IP:$(hostname -I | awk '{print $1}')"
    
    # Устанавливаем правильные права доступа
    chmod 600 /etc/ssl/xui/secret.key
    chmod 644 /etc/ssl/xui/cert.crt
    
    # Останавливаем сервис для безопасной работы с БД
    systemctl stop x-ui
    
    # Обновляем пути к SSL сертификатам в базе данных
    if [ -f /etc/x-ui/x-ui.db ]; then
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/etc/ssl/xui/cert.crt' WHERE key = 'webCertFile';"
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/etc/ssl/xui/secret.key' WHERE key = 'webKeyFile';"
        
        # Генерируем новые случайные данные для доступа
        USERNAME=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
        PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 16)
        BASEPATH=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        
        # Генерируем случайный порт
        PORT=$((RANDOM % 50000 + 10000))
        while [ $PORT -eq 22 ] || [ $PORT -eq 443 ] || [ $PORT -eq 80 ] || [ $PORT -eq 31228 ]; do
            PORT=$((RANDOM % 50000 + 10000))
        done
        
        # Получаем соль и генерируем хэш пароля
        SALT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT password FROM users WHERE id = 1;" | sed 's/\$2a\$10\$//' | cut -c1-22)
        if [ ! -z "$SALT" ]; then
            FULL_SALT="\$2a\$10\$${SALT}"
            
            HASH=$(python3 -c "
import bcrypt
password = '$PASSWORD'
salt = '$FULL_SALT'.encode('utf-8')
hashed = bcrypt.hashpw(password.encode('utf-8'), salt)
print(hashed.decode('utf-8'))
")
            
            # Обновляем данные пользователя
            sqlite3 /etc/x-ui/x-ui.db "UPDATE users SET username = '$USERNAME', password = '$HASH' WHERE id = 1;"
        fi
        
        # Обновляем настройки панели
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/$BASEPATH/' WHERE key = 'webBasePath';"
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '$PORT' WHERE key = 'webPort';"
        
        # Открываем порт в firewall
        ufw allow $PORT/tcp comment "X-UI Panel"
        
        # Запускаем сервис
        systemctl start x-ui
        
        # Выводим данные для доступа
        echo "=========================================="
        echo "         X-UI PANEL УСПЕШНО НАСТРОЕН"
        echo "=========================================="
        echo "URL: https://$(hostname -I | awk '{print $1}'):$PORT/$BASEPATH/"
        echo "Username: $USERNAME"
        echo "Password: $PASSWORD"
        echo "=========================================="
        echo "Сохраните эти данные в безопасном месте!"
        echo "=========================================="
        
        success "Установка и настройка завершены успешно!"
    else
        error "Файл базы данных не найден. Продолжаем без дополнительной настройки."
        systemctl start x-ui
    fi
    
    # Удаляем временные файлы
    rm -f /tmp/xui_install_continuation
    rm -f /root/continue_xui_install.sh
    
else
    error "Ошибка установки 3x-ui"
    exit 1
fi
CONTINUE_EOF

    chmod +x /root/continue_xui_install.sh
    
    # Добавляем скрипт в автозагрузку
    echo "@reboot root /root/continue_xui_install.sh && rm -f /root/continue_xui_install.sh" >> /etc/crontab
    
    log "Система будет перезагружена через 10 секунд..."
    log "ПОСЛЕ ПЕРЕЗАГРУЗКИ ПОЖАЛУЙСТА ПОДКЛЮЧИТЕСЬ К СЕРВЕРУ СНОВА!"
    log "Скрипт автоматически продолжит установку после вашего подключения"
    
    sleep 10
    reboot
}

# Основная функция установки
main_install() {
    log "Начало установки 3x-ui..."
    
    # Проверяем, является ли это продолжением после перезагрузки
    if is_continuation; then
        log "Обнаружено продолжение установки после перезагрузки"
        # Удаляем маркер продолжения
        rm -f /tmp/xui_install_continuation
        # Продолжаем установку
        /root/continue_xui_install.sh
    else
        log "Первичная установка"
        # Обновляем систему
        update_system
        # Перезагружаем систему
        reboot_system
    fi
}

# Проверка root прав
check_root

# Запуск основной установки
main_install
