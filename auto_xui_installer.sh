#!/bin/bash

# Скрипт автоматической установки 3x-ui с надежной перезагрузкой и автозапуском
# Версия: 2.1

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Глобальные переменные ---
SCRIPT_DIR="/root"
PHASE2_SCRIPT_NAME="xui_phase2_installer.sh"
PHASE2_SCRIPT_PATH="$SCRIPT_DIR/$PHASE2_SCRIPT_NAME"
SERVICE_NAME="xui-phase2-install.service"
SERVICE_FILE_PATH="/etc/systemd/system/$SERVICE_NAME"
STATE_FILE="/tmp/xui_install_state"
MARKER_FILE="/tmp/xui_phase2_marker"

# --- Функции логирования ---
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

# --- Проверки ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root"
    fi
}

check_internet() {
    log "Проверка подключения к интернету..."
    if ! ping -c 1 -W 5 8.8.8.8 &> /dev/null && ! ping -c 1 -W 5 1.1.1.1 &> /dev/null; then
        error "Нет подключения к интернету. Проверьте сетевые настройки."
    fi
    success "Подключение к интернету доступно."
}

# --- Управление состоянием ---
get_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "initial"
    fi
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

# --- Этап 1: Обновление системы ---
phase1_update_system() {
    log "Этап 1: Обновление системы..."
    set_state "updating"

    export DEBIAN_FRONTEND=noninteractive

    log "Обновление списков пакетов..."
    apt-get update -y || warn "Не удалось обновить списки пакетов apt"

    log "Обновление установленных пакетов..."
    apt-get upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" || warn "Не все пакеты были обновлены"

    log "Установка необходимых зависимостей..."
    apt-get install -y \
        curl wget sqlite3 openssl ufw net-tools tzdata \
        python3 python3-pip || error "Не удалось установить базовые зависимости"

    # Безопасная установка bcrypt
    log "Установка Python bcrypt..."
    if command -v pip3 &> /dev/null; then
        pip3 install --user bcrypt --quiet && log "Bcrypt установлен в пользовательскую директорию." && return 0
        warn "Установка в пользовательскую директорию не удалась, пробуем системную установку..."
        apt-get install -y python3-bcrypt && log "Bcrypt установлен через apt." && return 0
        warn "Установка через apt не удалась, пробуем pip с флагом --break-system-packages..."
        pip3 install bcrypt --break-system-packages --quiet && log "Bcrypt установлен через pip (с флагом --break-system-packages)." && return 0
    else
        apt-get install -y python3-bcrypt && log "Bcrypt установлен через apt (pip3 не найден)." && return 0
    fi
    error "Не удалось установить Python bcrypt всеми способами."
    success "Система обновлена"
}

# --- Этап 2: Настройка автозапуска продолжения ---
phase1_setup_autostart() {
    log "Этап 2: Настройка автозапуска второй фазы..."

    # 1. Создаем скрипт для второй фазы
    cat > "$PHASE2_SCRIPT_PATH" << 'PHASE2_EOF'
#!/bin/bash
set -e

# --- Цвета для второй фазы ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Функции логирования для второй фазы ---
log() {
    echo -e "${GREEN}[PHASE2]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[PHASE2_WARN]${NC} $1" >&2
}

error() {
    echo -e "${RED}[PHASE2_ERROR]${NC} $1" >&2
    # Удаляем маркер, чтобы основной скрипт знал об ошибке
    rm -f /tmp/xui_phase2_marker
    exit 1
}

success() {
    echo -e "${CYAN}[PHASE2_SUCCESS]${NC} $1"
}

# --- Основная логика второй фазы ---
log "Начало второй фазы установки: Установка 3x-ui и настройка..."

# --- Шаг 1: Установка 3x-ui через официальный скрипт ---
log "Шаг 1: Запуск официального установщика 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || error "Ошибка при запуске официального установщика 3x-ui"
success "3x-ui успешно установлен через официальный скрипт."

# --- Шаг 2: Ожидание инициализации сервиса ---
log "Шаг 2: Ожидание инициализации сервиса x-ui..."
sleep 15

# --- Шаг 3: Генерация и настройка SSL ---
log "Шаг 3: Генерация SSL-сертификата..."
mkdir -p /etc/ssl/xui

# Генерируем сертификат на 10 лет
if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/xui/secret.key \
    -out /etc/ssl/xui/cert.crt \
    -subj "/C=US/ST=State/L=City/O=X-UI-Panel/CN=$(hostname -I | awk '{print $1}')" \
    -addext "subjectAltName=DNS:$(hostname),IP:$(hostname -I | awk '{print $1}')" &>/dev/null; then
    chmod 600 /etc/ssl/xui/secret.key
    chmod 644 /etc/ssl/xui/cert.crt
    success "SSL-сертификат успешно создан."
else
    error "Не удалось создать SSL-сертификат."
fi

# --- Шаг 4: Настройка SSL в 3x-ui ---
log "Шаг 4: Настройка SSL-сертификатов в 3x-ui..."
systemctl stop x-ui

# Используем встроенную команду 3x-ui для установки SSL
if command -v x-ui &> /dev/null; then
    if x-ui setting -webCertFile "/etc/ssl/xui/cert.crt" -webKeyFile "/etc/ssl/xui/secret.key"; then
        success "Пути к SSL-сертификатам успешно установлены в 3x-ui."
    else
        error "Не удалось установить пути к SSL-сертификатам через команду x-ui."
    fi
else
    error "Команда x-ui не найдена после установки."
fi

# --- Шаг 5: Перезапуск сервиса ---
log "Шаг 5: Перезапуск сервиса x-ui..."
systemctl start x-ui || error "Не удалось запустить сервис x-ui после настройки SSL"
success "Сервис x-ui перезапущен."

# --- Шаг 6: Вывод финальной информации ---
log "Шаг 6: Получение финальных настроек..."
FINAL_SETTINGS=$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null || echo "Ошибка получения финальных настроек")
echo "=========================================="
echo "         X-UI PANEL УСПЕШНО НАСТРОЕН"
echo "=========================================="
echo "$FINAL_SETTINGS"
echo "=========================================="
echo "Сохраните эти данные в безопасном месте!"
echo "=========================================="

# --- Шаг 7: Очистка ---
log "Шаг 7: Очистка временных файлов второй фазы..."
# Создаем маркер успешного завершения
echo "completed" > /tmp/xui_phase2_marker
success "Вторая фаза установки завершена успешно!"
PHASE2_EOF

    chmod +x "$PHASE2_SCRIPT_PATH"

    # 2. Создаем systemd сервис для запуска второй фазы при следующей загрузке
    cat > "$SERVICE_FILE_PATH" << SERVICE_EOF
[Unit]
Description=Continue X-UI Installation After Reboot (Phase 2)
After=network.target

[Service]
Type=oneshot
ExecStart=$PHASE2_SCRIPT_PATH
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    # 3. Включаем сервис
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" || error "Не удалось включить сервис продолжения установки"
    success "Автозапуск второй фазы настроен. Сервис: $SERVICE_NAME"
}

# --- Этап 3: Перезагрузка ---
phase1_reboot() {
    log "Этап 3: Перезагрузка системы..."
    set_state "rebooting"
    log "Система будет перезагружена через 10 секунд..."
    log "ПОСЛЕ ПЕЗАГРУЗКИ ПОЖАЛУЙСТА ПОДКЛЮЧИТЕСЬ К СЕРВЕРУ СНОВА!"
    log "Скрипт автоматически продолжит установку (фаза 2)."
    sleep 10
    reboot
}

# --- Проверка и завершение ---
phase1_cleanup_and_wait() {
    log "Этап 4: Ожидание завершения второй фазы и очистка..."
    
    local wait_time=0
    local max_wait=300 # 5 минут
    
    # Ждем появления маркера завершения второй фазы
    while [[ ! -f "$MARKER_FILE" ]] && [[ $wait_time -lt $max_wait ]]; do
        log "Ожидание завершения второй фазы... (${wait_time}s)"
        sleep 10
        wait_time=$((wait_time + 10))
    done

    if [[ -f "$MARKER_FILE" ]] && [[ "$(cat "$MARKER_FILE")" == "completed" ]]; then
        success "Вторая фаза успешно завершена!"
        
        # Очистка: удаляем все временные файлы и сервис
        log "Очистка временных файлов..."
        rm -f "$STATE_FILE"
        rm -f "$MARKER_FILE"
        rm -f "$PHASE2_SCRIPT_PATH"
        
        systemctl disable "$SERVICE_NAME" --now &>/dev/null || true
        rm -f "$SERVICE_FILE_PATH"
        systemctl daemon-reload
        
        success "Все временные файлы и сервисы очищены."
        echo "=========================================="
        echo "         УСТАНОВКА ЗАВЕРШЕНА!"
        echo "=========================================="
        echo "Данные для доступа к панели см. выше."
        echo "=========================================="
    else
        error "Вторая фаза не завершилась в течение 5 минут или завершилась с ошибкой."
    fi
}

# --- Основной блок выполнения ---
main() {
    check_root
    check_internet

    local current_state=$(get_state)

    case "$current_state" in
        "initial"|"updating")
            log "Начало процесса установки. Текущее состояние: $current_state"
            phase1_update_system
            phase1_setup_autostart
            phase1_reboot
            ;;
        "rebooting")
            log "Обнаружено состояние 'rebooting'. Это неожиданно. Проверьте систему."
            # Если скрипт запущен после перезагрузки, это означает, что
            # systemd должен был запустить вторую фазу. Ждем и проверяем.
            phase1_cleanup_and_wait
            ;;
        *)
            log "Неизвестное состояние '$current_state'. Начинаем сначала."
            set_state "initial"
            main # Рекурсивный вызов для начала с начального состояния
            ;;
    esac
}

# --- Запуск ---
main "$@"
