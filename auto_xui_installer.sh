#!/bin/bash

# auto_xui_installer.sh - Скрипт автоматической установки и настройки 3x-ui
# Версия: 5.3

# --- Конфигурация ---
LOG_FILE="/tmp/xui_install_log_$(date +%s).txt" # Временный файл для лога установки с уникальным именем
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
if ! apt-get update > /dev/null 2>&1 || ! apt-get install -y curl openssl sqlite3 ufw net-tools > /dev/null 2>&1; then
    log_error "Ошибка при установке зависимостей."
    exit 1
fi
log_success "Зависимости установлены."

# --- Шаг 3: Запуск официального установщика 3x-ui с захватом лога ---
log "Запуск официального скрипта установки 3x-ui (автоматический режим)..."
# Удаляем временный файл, если он существует (на всякий случай)
rm -f "$LOG_FILE"

# Запуск установщика с автоматическим ответом "n" и перенаправлением вывода в файл и на экран
# Используем process substitution и tee для надежного захвата
exec 3< <({ echo "n"; } | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh))
tee "$LOG_FILE" <&3
INSTALLER_EXIT_CODE=${PIPESTATUS[1]} # Получаем код возврата установщика
exec 3<&- # Закрываем дескриптор

if [ $INSTALLER_EXIT_CODE -ne 0 ]; then
    log_error "Ошибка при выполнении официального скрипта установки 3x-ui (код $INSTALLER_EXIT_CODE). Смотрите лог: $LOG_FILE"
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
# Удаляем временный файл лога установки сразу после использования
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
# Используем INSERT OR REPLACE для надежного создания/обновления записей
if sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$CERT_CRT_FILE');" && \
   sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$CERT_KEY_FILE');" ; then
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
sleep 5 # Даем сервису время перезапуститься
log "Ожидание запуска HTTPS..."
# Проверяем лог сервиса на предмет запуска HTTPS
HTTPS_STARTED=false
for i in {1..20}; do
    if journalctl -u x-ui -n 10 --no-pager | grep -q "Web server running HTTPS"; then
        log_success "Сервис x-ui запущен с HTTPS."
        HTTPS_STARTED=true
        break
    fi
    sleep 2
done
if [ "$HTTPS_STARTED" = false ]; then
    log_warn "Не удалось подтвердить запуск HTTPS в логах x-ui. Проверьте 'journalctl -u x-ui'. Сервис может использовать HTTP или иметь ошибки конфигурации SSL."
    # Продолжаем выполнение, так как основная установка завершена
fi

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

# --- Шаг 10: Блокировка ICMP (ping) - Идемпотентная настройка ---
log "Блокировка ICMP (ping) запросов (идемпотентная настройка)..."

# Функция для безопасной замены ACCEPT на DROP в секции ICMP
safe_replace_accept_in_section() {
    local section_header="$1"
    if grep -q -- "^$section_header" "$BEFORE_RULES_FILE"; then
        # Создаем временную копию файла
        local temp_file=$(mktemp)
        # Копируем файл, заменяя ACCEPT на DROP только в пределах секции
        awk -v sec="$section_header" '
        BEGIN { in_section=0 }
        $0 ~ "^" sec { in_section=1; print; next }
        in_section && /^[^#]/ { gsub(/-j ACCEPT/, "-j DROP"); print; next }
        in_section && /^#/ { in_section=0; print; next }
        !in_section { print }
        ' "$BEFORE_RULES_FILE" > "$temp_file"
        # Заменяем оригинальный файл
        mv "$temp_file" "$BEFORE_RULES_FILE"
        log "Заменены правила ACCEPT->DROP в секции '$section_header'."
    else
        log_warn "Секция '$section_header' не найдена в $BEFORE_RULES_FILE."
    fi
}

# Функция для безопасного добавления правила source-quench, если его нет
safe_add_source_quench() {
    local rule="-A ufw-before-input -p icmp --icmp-type source-quench -j DROP"
    # Проверяем, существует ли правило уже (точное совпадение)
    if grep -qF -- "$rule" "$BEFORE_RULES_FILE"; then
        log "Правило source-quench уже существует."
    else
        # Ищем подходящую секцию для добавления
        local section_found=false
        for header in "# ok icmp codes for INPUT" "# ok icmp code for INPUT"; do
            if grep -q "^$header" "$BEFORE_RULES_FILE"; then
                # Находим последнюю строку секции (строку с DROP/ACCEPT перед следующим блоком или концом)
                # Это более надежный способ найти конец секции
                local start_line=$(grep -n "^$header" "$BEFORE_RULES_FILE" | cut -d: -f1)
                # Ищем следующую строку, начинающуюся с # или конец файла
                local end_marker=$(tail -n +$((start_line + 1)) "$BEFORE_RULES_FILE" | grep -n -m 1 "^#" | cut -d: -f1)
                local insert_line
                if [[ -n "$end_marker" ]]; then
                    insert_line=$((start_line + end_marker - 1))
                else
                    # Если нет следующего комментария, вставляем перед последней строкой файла
                    insert_line=$(wc -l < "$BEFORE_RULES_FILE")
                fi
                # Вставляем правило перед найденной строкой
                sed -i "${insert_line}i $rule" "$BEFORE_RULES_FILE"
                log "Правило source-quench добавлено в секцию '$header'."
                section_found=true
                break
            fi
        done
        if [ "$section_found" = false ]; then
            log_warn "Не найдена подходящая секция INPUT для добавления правила source-quench."
        fi
    fi
}

# Обрабатываем INPUT (учитываем оба варианта названия секции)
safe_replace_accept_in_section "# ok icmp codes for INPUT"
safe_replace_accept_in_section "# ok icmp code for INPUT"

# Обрабатываем FORWARD (учитываем оба варианта названия секции)
safe_replace_accept_in_section "# ok icmp codes for FORWARD"
safe_replace_accept_in_section "# ok icmp code for FORWARD"

# Добавляем source-quench в INPUT
safe_add_source_quench

# Перезагружаем UFW, чтобы применить изменения в before.rules
if ufw reload > /dev/null 2>&1; then
    log_success "ICMP (ping) запросы заблокированы (ufw reloaded)."
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
log "Важно: Так как используется самоподписанный сертификат, ваш браузер может предупредить о риске безопасности. Это нормальная реакция системы на сампоподписной сертификат!."
echo "========================================"
log_success "Скрипт выполнен успешно."
exit 0
