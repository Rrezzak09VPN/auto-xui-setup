#!/bin/bash

# auto_xui_installer.sh - Скрипт автоматической установки и настройки 3x-ui
# Версия: 2.0
# Использование: bash <(curl -Ls https://raw.githubusercontent.com/Rrezzak09VPN/auto-xui-setup/main/auto_xui_installer.sh)

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Функция логирования ---
log() {
    echo -e "${BLUE}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

# --- Переменные ---
DB_PATH="/etc/x-ui/x-ui.db"
CERT_DIR="/etc/ssl/xui"
CERT_KEY_FILE="$CERT_DIR/secret.key"
CERT_CRT_FILE="$CERT_DIR/cert.crt"
POST_INSTALL_MARKER="/tmp/.xui_post_install_done"

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен с правами root (sudo)."
   exit 1
fi

# --- Проверка, выполняется ли это как пост-установочный шаг ---
if [[ "$1" == "--post-install" ]]; then
    log "Начало пост-установочных задач..."
    # Удаляем маркер, если он остался от предыдущих запусков
    rm -f "$POST_INSTALL_MARKER"
    
    # --- Ждем, пока сервис полностью запустится и БД будет готова ---
    log "Ожидание инициализации сервиса и базы данных..."
    sleep 5 # Небольшая задержка
    
    local retries=30
    local count=0
    while [[ $count -lt $retries ]]; do
        if [[ -f "$DB_PATH" ]] && sqlite3 "$DB_PATH" "SELECT 1 FROM settings LIMIT 1;" > /dev/null 2>&1; then
            log_success "База данных готова."
            break
        fi
        log_warn "База данных еще не готова, повторная проверка через 2 секунды... ($((count+1))/$retries)"
        sleep 2
        ((count++))
    done

    if [[ $count -eq $retries ]]; then
        log_error "База данных не стала доступна после $retries попыток. Прерывание."
        exit 1
    fi

    # --- Шаг 1: Установка зависимостей для пост-обработки ---
    log "Установка зависимостей для пост-установочных задач..."
    apt-get update > /dev/null 2>&1 || log_warn "Не удалось обновить списки пакетов."
    apt-get install -y openssl sqlite3 ufw > /dev/null 2>&1 || { log_error "Не удалось установить зависимости для пост-установки."; exit 1; }
    log_success "Зависимости для пост-установки установлены."

    # --- Шаг 2: Генерация SSL сертификата ---
    log "Генерация самоподписанного SSL сертификата..."
    mkdir -p $CERT_DIR
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        log_warn "Не удалось автоматически определить IP-адрес сервера. Используется localhost для сертификата."
        SERVER_IP="localhost"
    fi

    if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_KEY_FILE" \
        -out "$CERT_CRT_FILE" \
        -subj "/C=US/ST=State/L=City/O=X-UI-Panel/CN=$SERVER_IP" \
        -addext "subjectAltName=DNS:$(hostname),IP:$SERVER_IP" > /dev/null 2>&1; then
        log_error "Ошибка при генерации SSL сертификата."
        exit 1
    fi

    chmod 600 "$CERT_KEY_FILE"
    chmod 644 "$CERT_CRT_FILE"
    log_success "SSL сертификат сгенерирован и сохранен в $CERT_DIR."

    # --- Шаг 3: Настройка путей к сертификатам в БД ---
    log "Обновление путей к сертификатам в настройках 3x-ui..."
    if [[ ! -f "$DB_PATH" ]]; then
        log_error "Файл базы данных 3x-ui не найден по пути $DB_PATH."
        exit 1
    fi

    # Используем INSERT OR REPLACE для надежности
    if ! sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$CERT_CRT_FILE');" > /dev/null 2>&1; then
        log_error "Ошибка при обновлении пути к файлу сертификата в базе данных."
        exit 1
    fi

    if ! sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$CERT_KEY_FILE');" > /dev/null 2>&1; then
        log_error "Ошибка при обновлении пути к файлу ключа в базе данных."
        exit 1
    fi

    log_success "Пути к сертификатам обновлены в базе данных."

    # --- Шаг 4: Перезапуск 3x-ui ---
    log "Перезапуск службы 3x-ui для применения настроек сертификата..."
    if ! systemctl restart x-ui > /dev/null 2>&1; then
        log_error "Ошибка при перезапуске службы x-ui."
        exit 1
    fi
    sleep 3 # Даем сервису время перезапуститься
    log_success "Служба 3x-ui перезапущена."

    # --- Шаг 5: Получение данных для входа из БД ---
    log "Получение данных для входа из настроек..."
    WEB_PORT=""
    DB_USERNAME=""
    DB_PASSWORD="" # Хэш, не показываем
    
    # Пытаемся получить из settings
    WEB_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
    DB_USERNAME=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='username';" 2>/dev/null)
    
    # Если не нашли в settings, пробуем получить из users (обычно admin)
    if [[ -z "$DB_USERNAME" ]]; then
         DB_USERNAME=$(sqlite3 "$DB_PATH" "SELECT username FROM users LIMIT 1;" 2>/dev/null)
    fi

    if [[ -z "$WEB_PORT" ]] || ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]]; then
        log_warn "Не удалось получить порт панели из БД. Используется порт по умолчанию 2053."
        WEB_PORT=2053
    fi

    if [[ -z "$DB_USERNAME" ]]; then
        log_warn "Не удалось получить имя пользователя из БД. Используется 'admin'."
        DB_USERNAME="admin"
    fi

    log "Порт панели: $WEB_PORT"
    log "Имя пользователя: $DB_USERNAME"

    # --- Шаг 6: Настройка UFW (фаерволл) ---
    log "Настройка UFW: открытие нужных портов и закрытие остальных..."
    
    # Включение UFW, если он не активен
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable > /dev/null 2>&1 || { log_error "Не удалось включить UFW."; exit 1; }
        log_success "UFW включен."
    fi

    # Сброс правил для чистой конфигурации
    ufw --force reset > /dev/null 2>&1

    # Открытие необходимых портов
    ufw allow 22/tcp > /dev/null 2>&1 || log_warn "Не удалось открыть порт 22 (SSH)."
    ufw allow 443/tcp > /dev/null 2>&1 || log_warn "Не удалось открыть порт 443 (HTTPS)."
    ufw allow $WEB_PORT/tcp > /dev/null 2>&1 || log_warn "Не удалось открыть порт $WEB_PORT (Панель 3x-ui)."

    # Запрет всех остальных входящих соединений по умолчанию
    ufw default deny incoming > /dev/null 2>&1 || log_warn "Не удалось установить правило запрета входящих по умолчанию."

    # Разрешение всех исходящих соединений по умолчанию
    ufw default allow outgoing > /dev/null 2>&1 || log_warn "Не удалось установить правило разрешения исходящих по умолчанию."

    # Перезагрузка UFW для применения всех правил
    ufw --force reload > /dev/null 2>&1 || log_warn "Не удалось перезагрузить UFW."
    log_success "Настройка UFW завершена."

    # --- Шаг 7: Блокировка ICMP в UFW ---
    log "Блокировка ICMP (ping) запросов..."
    BEFORE_RULES_FILE="/etc/ufw/before.rules"

    # Создание резервной копии
    cp "$BEFORE_RULES_FILE" "${BEFORE_RULES_FILE}.bak_$(date +%Y%m%d_%H%M%S)" > /dev/null 2>&1 || log_warn "Не удалось создать резервную копию $BEFORE_RULES_FILE."

    # Функция для замены или добавления правил DROP для ICMP
    block_icmp_types() {
        local section="$1"
        local types=("destination-unreachable" "time-exceeded" "parameter-problem" "echo-request" "source-quench")

        # Проверяем, существует ли секция
        if ! grep -q "^# ok icmp codes for $section" "$BEFORE_RULES_FILE"; then
             log_error "Секция '# ok icmp codes for $section' не найдена в $BEFORE_RULES_FILE. Пропуск настройки ICMP для этой секции."
             return 1
        fi

        for type in "${types[@]}"; do
            # Проверяем, есть ли правило для этого типа
            if grep -q "\-\-icmp-type $type" "$BEFORE_RULES_FILE"; then
                # Заменяем ACCEPT на DROP
                sed -i "/--icmp-type $type/s/-j ACCEPT/-j DROP/" "$BEFORE_RULES_FILE"
                log_debug "Правило для $type в $section изменено на DROP."
            else
                # Добавляем правило DROP перед # End of ok icmp codes
                sed -i "/# End of ok icmp codes for $section/i -A ufw-before-$section -p icmp --icmp-type $type -j DROP" "$BEFORE_RULES_FILE"
                log_debug "Правило DROP для $type добавлено в $section."
            fi
        done
    }

    block_icmp_types "INPUT"
    block_icmp_types "FORWARD"

    # Перезагрузка UFW для применения изменений в before.rules
    ufw --force reload > /dev/null 2>&1 || log_warn "Не удалось перезагрузить UFW после изменения ICMP правил."
    log_success "ICMP (ping) запросы заблокированы."

    # --- Шаг 8: Получение информации о статусе и открытых портах ---
    log "Сбор информации о установленной панели..."

    # Получение статуса службы
    XUI_STATUS=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
    if [[ "$XUI_STATUS" != "active" ]]; then
        log_warn "Служба x-ui не активна. Текущий статус: $XUI_STATUS"
    else
        log_success "Служба x-ui активна."
    fi

    # Получение открытых портов (после настройки UFW)
    OPEN_PORTS=$(ufw status numbered 2>/dev/null | grep -E 'ALLOW|DENY|LIMIT' | head -n 15) # Ограничиваем вывод
    if [[ -z "$OPEN_PORTS" ]]; then
        OPEN_PORTS_INFO="Не удалось определить открытые порты или их нет."
    else
        OPEN_PORTS_INFO="$OPEN_PORTS"
    fi

    # --- Шаг 9: Вывод результатов ---
    echo ""
    echo "========================================"
    log_success "Установка и настройка 3x-ui завершена!"
    echo "========================================"
    echo ""

    log "Статус службы x-ui: $XUI_STATUS"
    echo ""
    log "Открытые порты (после настройки UFW):"
    echo "$OPEN_PORTS_INFO"
    echo ""
    log "Данные для входа в панель:"
    echo "  URL: https://$(hostname -I | awk '{print $1}'):$WEB_PORT/"
    echo "  Логин: $DB_USERNAME"
    echo "  Пароль: [Пароль был установлен автоматически при установке. Проверьте его в панели после первого входа.]"
    echo ""
    log "Пути к сертификатам:"
    echo "  Приватный ключ: $CERT_KEY_FILE"
    echo "  Сертификат: $CERT_CRT_FILE"
    echo ""
    log "Важно: Так как используется самоподписанный сертификат, ваш браузер может предупредить о риске безопасности. Это нормально для тестовой среды."
    echo "========================================"
    echo ""

    log_success "Скрипт выполнен успешно. Пожалуйста, сохраните эти данные для входа в панель."
    exit 0
fi

# --- Если это первый запуск скрипта ---
echo "========================================"
log "Начало автоматической установки и настройки 3x-ui"
echo "========================================"
log "Сейчас будет запущен официальный установщик 3x-ui."
log "Пожалуйста, следуйте инструкциям установщика для генерации учетных данных."
log "После завершения установки и выхода из терминала, автоматически продолжится настройка SSL, фаервола и т.д."
echo ""

# Создаем маркер для пост-установочного шага
touch "$POST_INSTALL_MARKER"

# --- Шаг 1: Установка зависимостей для установки ---
log "Установка необходимых зависимостей для запуска установщика..."
apt-get update > /dev/null 2>&1 || log_warn "Не удалось обновить списки пакетов."
apt-get install -y curl > /dev/null 2>&1 || { log_error "Не удалось установить curl."; exit 1; }
log_success "Зависимости для установки установлены."

# --- Шаг 2: Запуск официального скрипта установки 3x-ui ---
log "Запуск официального скрипта установки 3x-ui..."
log "Вы будете перенаправлены в интерактивный режим установщика."
log "После завершения установки и выхода из терминала, скрипт автоматически продолжит работу."
echo ""

# Используем exec для замены текущего процесса, чтобы пост-установка могла запуститься после выхода
# Мы передаем команду, которая после установки снова вызовет этот скрипт с флагом --post-install
exec bash -c "
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    echo '========================================'
    echo '[INFO]$(date '+%Y-%m-%d %H:%M:%S') Установщик 3x-ui завершил работу.'
    echo '[INFO]$(date '+%Y-%m-%d %H:%M:%S') Запуск пост-установочных задач...'
    echo '========================================'
    $(realpath $0) --post-install
"
