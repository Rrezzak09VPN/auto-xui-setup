#!/bin/bash

# auto_xui_installer.sh - Скрипт автоматической установки и настройки 3x-ui
# Версия: 5.1

# --- Конфигурация ---
LOG_FILE="/tmp/xui_install_log.txt" # Временный файл для лога установки
CERT_DIR="/etc/ssl/xui"
CERT_CRT_FILE="$CERT_DIR/cert.crt"
CERT_KEY_FILE="$CERT_DIR/secret.key"
DB_PATH="/etc/x-ui/x-ui.db"
BEFORE_RULES_FILE="/etc/ufw/before.rules"
# --------------------

# --- Функции логирования ---
log() { echo "[INFO]$(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn() { echo "[WARNING]$(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo "[ERROR]$(date '+%Y-%m-%d %H:%M:%S') $1" >&2; }
log_success() { echo "[SUCCESS]$(date '+%Y-%m-%d %H:%M:%S') $1"; }
# --------------------------

echo "========================================"
log "Начало автоматической установки и настройки 3x-ui"
echo "========================================"

# --- Шаг 1: Проверка root прав ---
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен с правами root."
   exit 1
fi

# --- Шаг 2: Установка зависимостей ---
log "Установка необходимых зависимостей..."
if ! apt-get update > /dev/null 2>&1 || ! apt-get install -y curl openssl sqlite3 ufw > /dev/null 2>&1; then
    log_error "Ошибка при установке зависимостей."
    exit 1
fi
log_success "Зависимости установлены."

# --- Шаг 3: Запуск официального установщика 3x-ui с захватом лога ---
log "Запуск официального скрипта установки 3x-ui (автоматический режим)..."
# Удаляем временный файл, если он существует
rm -f "$LOG_FILE"

# Запуск установщика с автоматическим ответом "n" и перенаправлением вывода в файл
{ echo "n"; } | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > "$LOG_FILE" 2>&1

# Проверяем код возврата предыдущей команды
if [ $? -ne 0 ]; then
    log_error "Ошибка при выполнении официального скрипта установки 3x-ui. Смотрите лог: $LOG_FILE"
    # Не удаляем лог, чтобы можно было отладить
    exit 1
fi
log_success "3x-ui установлен."

# --- Шаг 4: Извлечение учетных данных из лога установки ---
log "Извлечение учетных данных из лога установки..."
# Инициализируем переменные
EXTRACTED_USERNAME=""
EXTRACTED_PASSWORD=""
EXTRACTED_PORT=""
EXTRACTED_WEBBASEPATH=""
EXTRACTED_URL=""

# Используем grep и sed для извлечения
EXTRACTED_USERNAME=$(grep -oP 'Username:\s*\K\w+' "$LOG_FILE" | head -n 1)
EXTRACTED_PASSWORD=$(grep -oP 'Password:\s*\K\w+' "$LOG_FILE" | head -n 1)
EXTRACTED_PORT=$(grep -oP 'Port:\s*\K\d+' "$LOG_FILE" | head -n 1)
EXTRACTED_WEBBASEPATH=$(grep -oP 'WebBasePath:\s*\K[^[:space:]]+' "$LOG_FILE" | head -n 1)
EXTRACTED_URL=$(grep -oP 'Access URL:\s*\Khttp[^[:space:]]+' "$LOG_FILE" | head -n 1)

if [[ -z "$EXTRACTED_USERNAME" || -z "$EXTRACTED_PASSWORD" || -z "$EXTRACTED_PORT" || -z "$EXTRACTED_WEBBASEPATH" ]]; then
    log_error "Не удалось извлечь все учетные данные из лога установки."
    log "Проверьте лог установки: $LOG_FILE"
    # Не удаляем лог при ошибке
    exit 1
fi

log "Учетные данные успешно извлечены из лога."
# Удаляем временный файл лога установки
rm -f "$LOG_FILE"
log "Временный файл лога установки удален."

# --- Шаг 5: Ожидание инициализации сервиса и базы данных ---
log "Ожидание инициализации сервиса и базы данных..."
sleep 5 # Даем сервису время стартовать и создать БД

# Ожидание появления файла БД
for i in {1..30}; do
    if [[ -f "$DB_PATH" ]]; then
        log_success "База данных готова."
        break
    fi
    sleep 1
done
if [[ ! -f "$DB_PATH" ]]; then
    log_error "Файл базы данных $DB_PATH не появился в течение ожидания."
    exit 1
fi

# --- Шаг 6: Генерация SSL сертификата ---
log "Генерация самоподписанного SSL сертификата..."
mkdir -p "$CERT_DIR"
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

# --- Шаг 7: Обновление путей к сертификатам в БД ---
log "Обновление путей к сертификатам в настройках 3x-ui..."
# Проверяем, существуют ли записи в settings, если нет - вставляем
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key = 'webCertFile' LIMIT 1;" &>/dev/null; then
    sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO settings (key, value) VALUES ('webCertFile', '$CERT_CRT_FILE');"
fi
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key = 'webKeyFile' LIMIT 1;" &>/dev/null; then
    sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO settings (key, value) VALUES ('webKeyFile', '$CERT_KEY_FILE');"
fi
# Обновляем значения
if sqlite3 "$DB_PATH" "UPDATE settings SET value = '$CERT_CRT_FILE' WHERE key = 'webCertFile';" && \
   sqlite3 "$DB_PATH" "UPDATE settings SET value = '$CERT_KEY_FILE' WHERE key = 'webKeyFile';"; then
    log_success "Пути к сертификатам обновлены в базе данных."
else
    log_error "Ошибка при обновлении путей к сертификатам в базе данных."
    exit 1
fi

# --- Шаг 8: Перезапуск 3x-ui ---
log "Перезапуск службы 3x-ui для применения настроек сертификата..."
if ! systemctl restart x-ui > /dev/null 2>&1; then
    log_error "Ошибка при перезапуске службы x-ui."
    exit 1
fi
sleep 3 # Даем сервису время перезапуститься
log_success "Служба 3x-ui перезапущена."

# --- Шаг 9: Настройка UFW ---
log "Настройка UFW: открытие нужных портов..."
# Открываем SSH, HTTPS и порт панели
if ufw allow 22/tcp > /dev/null 2>&1 && \
   ufw allow 443/tcp > /dev/null 2>&1 && \
   ufw allow "$EXTRACTED_PORT"/tcp > /dev/null 2>&1 && \
   ufw --force enable > /dev/null 2>&1; then
    log_success "UFW настроен и включен."
else
    log_error "Ошибка при настройке UFW."
    exit 1
fi

# --- Шаг 10: Блокировка ICMP (ping) ---
log "Блокировка ICMP (ping) запросов..."
# Правила для INPUT
if grep -q "# ok icmp codes for INPUT" "$BEFORE_RULES_FILE"; then
    # Заменяем ACCEPT на DROP для существующих правил INPUT
    sed -i '/# ok icmp codes for INPUT/,/^[^#]/ s/-j ACCEPT/-j DROP/g' "$BEFORE_RULES_FILE"
    # Удаляем возможные дубликаты source-quench, если они были добавлены ранее (на случай повторного запуска)
    sed -i '/# ok icmp codes for INPUT/,/^[^#]/ {/source-quench/d;}' "$BEFORE_RULES_FILE"
    # Добавляем правило source-quench в конец секции INPUT
    sed -i '/# ok icmp codes for INPUT/,/^[^#]/ { /^[^#]/i\-A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$BEFORE_RULES_FILE"
else
    log_warn "Секция '# ok icmp codes for INPUT' не найдена в $BEFORE_RULES_FILE. Пропуск настройки ICMP INPUT."
fi

# Перезагружаем UFW, чтобы применить изменения в before.rules
if ufw reload > /dev/null 2>&1; then
    log_success "ICMP (ping) запросы заблокированы."
else
    log_error "Ошибка при перезагрузке UFW для применения правил ICMP."
    # Не завершаем с ошибкой, так как основная функциональность может работать
fi

# --- Шаг 11: Сбор информации ---
log "Сбор информации о установленной панели..."
# Проверка статуса сервиса
if systemctl is-active --quiet x-ui; then
    SERVICE_STATUS="active"
else
    SERVICE_STATUS="inactive"
fi

# Получение открытых портов из UFW
OPEN_PORTS_INFO=$(ufw status numbered 2>/dev/null | grep -E "(ALLOW IN|DENY IN)" | head -n 10) # Ограничиваем вывод первыми 10 строками
if [[ -z "$OPEN_PORTS_INFO" ]]; then
    OPEN_PORTS_INFO="Не удалось получить список открытых портов или список пуст."
fi

# Формирование корректного URL (используем извлеченные данные)
# Убираем ведущий слэш из webBasePath, если он есть, чтобы избежать двойного слэша
FORMATTED_WEBBASEPATH=$(echo "$EXTRACTED_WEBBASEPATH" | sed 's|^/||')
FINAL_PANEL_URL="https://$(hostname -I | awk '{print $1}'):$EXTRACTED_PORT/$FORMATTED_WEBBASEPATH"

log_success "Установка и настройка 3x-ui завершена!"
echo "========================================"
log "Статус службы x-ui: $SERVICE_STATUS"
echo ""
log "Открытые порты (после настройки UFW):"
echo "$OPEN_PORTS_INFO"
echo ""
log "Данные для входа в панель:"
echo "  URL: $FINAL_PANEL_URL"
echo "  Логин: $EXTRACTED_USERNAME"
echo "  Пароль: $EXTRACTED_PASSWORD"
echo ""
log "Пути к сертификатам:"
echo "  Приватный ключ: $CERT_KEY_FILE"
echo "  Сертификат: $CERT_CRT_FILE"
echo ""
log "Важно: Так как используется самоподписанный сертификат, ваш браузер может предупредить о риске безопасности. Это нормально для тестовой среды."
echo "========================================"
log_success "Скрипт выполнен успешно."
exit 0
