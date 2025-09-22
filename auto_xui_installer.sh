#!/bin/bash

# auto_xui_installer.sh - Скрипт автоматической установки и настройки 3x-ui
# Версия: 1.3
# Использование: bash <(curl -Ls https://raw.githubusercontent.com/Rrezzak09VPN/auto-xui-setup/main/auto_xui_installer.sh)

set -e

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

log_debug() {
    # Включите для отладки, закомментируйте для обычного режима
    # echo -e "${PURPLE}[DEBUG]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    :
}

# --- Переменные ---
DB_PATH="/etc/x-ui/x-ui.db"
CERT_DIR="/etc/ssl/xui"
CERT_KEY_FILE="$CERT_DIR/secret.key"
CERT_CRT_FILE="$CERT_DIR/cert.crt"

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен с правами root (sudo)."
   exit 1
fi

# --- Начало установки ---
echo "========================================"
log "Начало автоматической установки и настройки 3x-ui"
echo "========================================"

# --- Шаг 1: Установка зависимостей ---
log "Установка необходимых зависимостей..."
apt-get update > /dev/null 2>&1 || log_warn "Не удалось обновить списки пакетов. Продолжаем с текущими."
apt-get install -y curl openssl sqlite3 ufw > /dev/null 2>&1 || { log_error "Не удалось установить необходимые зависимости."; exit 1; }
log_success "Зависимости установлены."

# --- Шаг 2: Установка 3x-ui ---
log "Запуск официального скрипта установки 3x-ui..."
# Используем yes для автоматического подтверждения
if ! yes | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > /dev/null 2>&1; then
    log_error "Ошибка при выполнении официального скрипта установки 3x-ui."
    exit 1
fi
log_success "3x-ui установлен."

# --- Шаг 3: Генерация SSL сертификата ---
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

# --- Шаг 4: Настройка путей к сертификатам в БД ---
log "Обновление путей к сертификатам в настройках 3x-ui..."
if [[ ! -f "$DB_PATH" ]]; then
    log_error "Файл базы данных 3x-ui не найден по пути $DB_PATH."
    exit 1
fi

# Проверим текущие записи в таблице settings для отладки
log_debug "Текущие записи в таблице settings, связанные с сертификатами:"
sqlite3 "$DB_PATH" "SELECT key, value FROM settings WHERE key LIKE '%Cert%' OR key LIKE '%Key%';" 2>/dev/null || log_debug "Не удалось получить записи о сертификатах."

# Функция для обновления или вставки значения в таблицу settings
# Использует INSERT OR REPLACE для корректной работы
update_or_insert_setting() {
    local key_name="$1"
    local value_name="$2"
    log_debug "Попытка обновления/вставки: $key_name = $value_name"

    # Проверяем, существует ли запись
    local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM settings WHERE key='$key_name';" 2>/dev/null || echo "0")

    if [[ "$count" -gt 0 ]]; then
        # Запись существует, обновляем
        if sqlite3 "$DB_PATH" "UPDATE settings SET value='$value_name' WHERE key='$key_name';" > /dev/null 2>&1; then
            log_debug "Запись $key_name обновлена."
        else
            log_error "Ошибка при обновлении записи $key_name."
            return 1
        fi
    else
        # Записи нет, вставляем новую
        # Нам нужно определить следующий id. Проще использовать INSERT OR REPLACE.
        # Но для этого нужно знать все поля. Предположим, что id автоинкрементируется или мы можем его опустить.
        # Лучше использовать INSERT OR REPLACE напрямую.
        if sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('$key_name', '$value_name');" > /dev/null 2>&1; then
            log_debug "Запись $key_name вставлена или заменена."
        else
            log_error "Ошибка при вставке/замене записи $key_name."
            return 1
        fi
    fi
}

# Обновляем или вставляем пути к сертификатам
if ! update_or_insert_setting "webCertFile" "$CERT_CRT_FILE"; then
    log_error "Ошибка при обработке пути к файлу сертификата ($CERT_CRT_FILE)."
    # Попробуем альтернативный метод: прямой INSERT OR REPLACE
    if ! sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$CERT_CRT_FILE');" > /dev/null 2>&1; then
        log_error "Альтернативный метод: Ошибка при обновлении пути к файлу сертификата в базе данных."
        exit 1
    else
        log_debug "Альтернативный метод: Путь к файлу сертификата обновлен."
    fi
fi

if ! update_or_insert_setting "webKeyFile" "$CERT_KEY_FILE"; then
    log_error "Ошибка при обработке пути к файлу ключа ($CERT_KEY_FILE)."
    # Попробуем альтернативный метод
    if ! sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$CERT_KEY_FILE');" > /dev/null 2>&1; then
        log_error "Альтернативный метод: Ошибка при обновлении пути к файлу ключа в базе данных."
        exit 1
    else
        log_debug "Альтернативный метод: Путь к файлу ключа обновлен."
    fi
fi

log_success "Пути к сертификатам обновлены в базе данных."

# --- Шаг 5: Перезапуск 3x-ui ---
log "Перезапуск службы 3x-ui для применения настроек сертификата..."
if ! systemctl restart x-ui > /dev/null 2>&1; then
    log_error "Ошибка при перезапуске службы x-ui."
    exit 1
fi
log_success "Служба 3x-ui перезапущена."

# --- Шаг 6: Получение порта панели и данных пользователя ---
log "Получение данных для входа из настроек..."
if [[ ! -f "$DB_PATH" ]]; then
    log_error "Файл базы данных 3x-ui не найден по пути $DB_PATH."
    exit 1
fi

WEB_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
DB_USERNAME=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='username';" 2>/dev/null)
DB_PASSWORD=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='password';" 2>/dev/null)

if [[ -z "$WEB_PORT" ]] || ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]]; then
    log_warn "Не удалось получить порт панели из БД. Используется порт по умолчанию 2053."
    WEB_PORT=2053
fi

if [[ -z "$DB_USERNAME" ]]; then
    log_warn "Не удалось получить имя пользователя из БД."
    DB_USERNAME="Не определено"
fi

if [[ -z "$DB_PASSWORD" ]]; then
    log_warn "Не удалось получить пароль из БД."
    DB_PASSWORD="Не определено"
fi

log "Порт панели: $WEB_PORT"
log "Имя пользователя: $DB_USERNAME"
# Пароль не выводим, так как он зашифрован

# --- Шаг 7: Настройка UFW (фаерволл) ---
log "Настройка UFW: открытие нужных портов и закрытие остальных..."
# Включение UFW, если он не активен
if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable > /dev/null 2>&1 || log_warn "Не удалось автоматически включить UFW."
fi

# Сброс правил (на случай, если были установлены ранее)
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

# --- Шаг 8: Блокировка ICMP в UFW ---
log "Блокировка ICMP (ping) запросов..."
BEFORE_RULES_FILE="/etc/ufw/before.rules"

# Создание резервной копии
cp "$BEFORE_RULES_FILE" "${BEFORE_RULES_FILE}.bak_$(date +%Y%m%d_%H%M%S)" > /dev/null 2>&1 || log_warn "Не удалось создать резервную копию $BEFORE_RULES_FILE."

# Функция для замены правил ACCEPT на DROP или добавления новых
replace_or_add_icmp_rules() {
    local section="$1"

    # Проверяем, существует ли секция
    if grep -q "^# ok icmp codes for $section" "$BEFORE_RULES_FILE"; then
        # Заменяем существующие ACCEPT на DROP
        sed -i "/^# ok icmp codes for $section/,/^# End of ok icmp codes for $section/ s/-j ACCEPT/-j DROP/g" "$BEFORE_RULES_FILE"
        log_debug "Правила ACCEPT в секции $section заменены на DROP."
    else
        # Если секции нет, создаем её перед # End required lines
        line_num=$(grep -n "^# End required lines" "$BEFORE_RULES_FILE" | cut -d: -f1)
        if [[ -n "$line_num" ]]; then
            sed -i "${line_num}i # ok icmp codes for $section\n# End of ok icmp codes for $section\n" "$BEFORE_RULES_FILE"
            log_debug "Секция $section добавлена."
        else
             # Если # End required lines не найдена, добавляем в конец
             echo -e "\n# ok icmp codes for $section\n# End of ok icmp codes for $section" >> "$BEFORE_RULES_FILE"
             log_debug "Секция $section добавлена в конец файла."
        fi
    fi

    # Добавляем или заменяем правила DROP
    local rules=(
        "destination-unreachable"
        "time-exceeded"
        "parameter-problem"
        "echo-request"
        "source-quench"
    )

    for rule_type in "${rules[@]}"; do
        if grep -q "\-\-icmp-type $rule_type" "$BEFORE_RULES_FILE"; then
            sed -i "/--icmp-type $rule_type/s/-j ACCEPT/-j DROP/" "$BEFORE_RULES_FILE"
            log_debug "Правило $rule_type в секции $section обновлено на DROP."
        else
            # Добавляем правило перед # End of ok icmp codes
            sed -i "/# End of ok icmp codes for $section/i -A ufw-before-$section -p icmp --icmp-type $rule_type -j DROP" "$BEFORE_RULES_FILE"
            log_debug "Правило $rule_type добавлено в секцию $section."
        fi
    done
}

replace_or_add_icmp_rules "INPUT"
replace_or_add_icmp_rules "FORWARD"

# Перезагрузка UFW для применения изменений в before.rules
ufw --force reload > /dev/null 2>&1 || log_warn "Не удалось перезагрузить UFW после изменения ICMP правил."
log_success "ICMP (ping) запросы заблокированы."

# --- Шаг 9: Получение информации о статусе и открытых портах ---
log "Сбор информации о установленной панели..."

# Получение статуса службы
XUI_STATUS=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
if [[ "$XUI_STATUS" != "active" ]]; then
    log_warn "Служба x-ui не активна. Текущий статус: $XUI_STATUS"
else
    log_success "Служба x-ui активна."
fi

# Получение открытых портов (после настройки UFW)
OPEN_PORTS=$(ufw status numbered 2>/dev/null | grep -E 'ALLOW|DENY|LIMIT' | head -n 10) # Ограничиваем вывод первыми 10 строками
if [[ -z "$OPEN_PORTS" ]]; then
    OPEN_PORTS_INFO="Не удалось определить открытые порты или их нет."
else
    OPEN_PORTS_INFO="$OPEN_PORTS"
fi

# --- Шаг 10: Вывод результатов ---
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
