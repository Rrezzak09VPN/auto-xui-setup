#!/bin/bash

# auto_xui_installer.sh - Автоматическая установка 3x-ui + VLESS+Reality inbound (3 клиента)
# Версия: 6.1
# Обновлено: 18 ноября 2025 г.
# Особенности:
#   ✅ Чистая установка 3x-ui
#   ✅ SSL для панели (самоподписанный)
#   ✅ UFW + блокировка ICMP
#   ✅ Reality inbound на порту 443 (VLESS/TCP)
#   ✅ 3 клиента с flow=xtls-rprx-vision
#   ✅ Генерация ссылок подключения
#   ✅ Проверка портов, бэкап БД, rollback при ошибке

# --- Конфигурация ---
LOG_FILE="/tmp/xui_install_log_$(date +%s).txt"
CERT_DIR="/etc/ssl/xui"
CERT_CRT_FILE="$CERT_DIR/cert.crt"
CERT_KEY_FILE="$CERT_DIR/secret.key"
DB_PATH="/etc/x-ui/x-ui.db"
BEFORE_RULES_FILE="/etc/ufw/before.rules"
XRAY_BIN="/usr/local/x-ui/bin/xray"
REALITY_PORT=443
REALITY_TARGET="github.com:443"
REALITY_SERVERNAMES=("github.com" "www.github.com")
REALITY_FINGERPRINT="chrome"
REALITY_SPIDERX="/"
# --------------------

# --- Функции логирования ---
log() { echo "[INFO]$(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn() { echo "[WARNING]$(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo "[ERROR]$(date '+%Y-%m-%d %H:%M:%S') $1" >&2; }
log_success() { echo "[SUCCESS]$(date '+%Y-%m-%d %H:%M:%S') $1"; }
# --------------------------

# --- Вспомогательные функции ---
generate_sub_id() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c 16
}

generate_short_id() {
    openssl rand -hex $((2 + RANDOM % 7))
}
# --------------------------

echo "========================================"
log "🚀 Начало автоматической установки 3x-ui (v6.1)"
log "   Включая VLESS+Reality inbound и 3 клиента"
echo "========================================"

# --- Шаг 1: Проверка root прав ---
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен от root."
   exit 1
fi

# --- Шаг 2: Установка зависимостей ---
log "📦 Установка зависимостей..."
if ! apt-get update > /dev/null 2>&1 || ! apt-get install -y curl openssl sqlite3 ufw net-tools uuid-runtime > /dev/null 2>&1; then
    log_error "Ошибка установки зависимостей."
    exit 1
fi
log_success "Зависимости установлены."

# --- Шаг 3: Запуск официального установщика ---
log "📥 Запуск установщика 3x-ui..."
rm -f "$LOG_FILE"

exec 3< <({ echo "n"; } | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh))
tee "$LOG_FILE" <&3
INSTALLER_EXIT_CODE=${PIPESTATUS[1]}
exec 3<&-

if [[ $INSTALLER_EXIT_CODE -ne 0 ]]; then
    log_error "Ошибка установки 3x-ui (код $INSTALLER_EXIT_CODE)."
    log "Лог: $LOG_FILE"
    exit 1
fi
log_success "3x-ui установлен."

# --- Шаг 4: Извлечение учетных данных ---
log "🔑 Извлечение данных панели..."
EXTRACTED_USERNAME=$(grep -oP 'Username:\s*\K\w+' "$LOG_FILE" | head -n1)
EXTRACTED_PASSWORD=$(grep -oP 'Password:\s*\K\w+' "$LOG_FILE" | head -n1)
EXTRACTED_PORT=$(grep -oP 'Port:\s*\K\d+' "$LOG_FILE" | head -n1)
EXTRACTED_WEBBASEPATH=$(grep -oP 'WebBasePath:\s*\K[^[:space:]]+' "$LOG_FILE" | head -n1)

if [[ -z "$EXTRACTED_USERNAME" || -z "$EXTRACTED_PASSWORD" || -z "$EXTRACTED_PORT" || -z "$EXTRACTED_WEBBASEPATH" ]]; then
    log_error "Не удалось извлечь учетные данные."
    exit 1
fi
rm -f "$LOG_FILE"
log "Данные панели получены."

# --- Шаг 5: Ожидание БД ---
log "⏳ Ожидание инициализации БД..."
for i in {1..30}; do
    [[ -f "$DB_PATH" ]] && break
    sleep 1
done
[[ ! -f "$DB_PATH" ]] && { log_error "БД не создана."; exit 1; }
log_success "БД готова."

# --- Шаг 6: SSL для панели ---
log "🔐 Генерация SSL для панели..."
mkdir -p "$CERT_DIR"
SERVER_IP=$(hostname -I | awk '{print $1}'); [[ -z "$SERVER_IP" ]] && SERVER_IP="localhost"

if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CERT_KEY_FILE" -out "$CERT_CRT_FILE" \
    -subj "/C=US/ST=State/L=City/O=X-UI/CN=$SERVER_IP" \
    -addext "subjectAltName=DNS:$(hostname),IP:$SERVER_IP" > /dev/null 2>&1; then
    log_error "Ошибка генерации SSL."
    exit 1
fi
chmod 600 "$CERT_KEY_FILE" && chmod 644 "$CERT_CRT_FILE"
log_success "SSL сертификат создан."

# --- Шаг 7: Обновление путей в БД ---
log "💾 Обновление путей к сертификатам в БД..."
sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$CERT_CRT_FILE');" ||
    { log_error "Не удалось обновить webCertFile."; exit 1; }
sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$CERT_KEY_FILE');" ||
    { log_error "Не удалось обновить webKeyFile."; exit 1; }
log_success "Пути к сертификатам обновлены."

# --- Шаг 8: Перезапуск панели ---
log "🔄 Перезапуск x-ui..."
systemctl restart x-ui
sleep 5

# --- Шаг 9: Настройка UFW ---
log "🛡️  Настройка UFW..."
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow "$EXTRACTED_PORT"/tcp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ufw reload >/dev/null 2>&1
log_success "UFW настроен."

# --- Шаг 10: Блокировка ICMP (ping) ---
log "🔇 Блокировка ICMP (ping)..."
safe_replace_accept_in_section() {
    local sec="$1"
    grep -q "^$sec" "$BEFORE_RULES_FILE" || return 0
    local tmp=$(mktemp)
    awk -v s="$sec" '
        $0~"^"s{in_sec=1;print;next}
        in_sec&&/^[^#]/{gsub(/-j ACCEPT/,"-j DROP");print;next}
        in_sec&&/^#/{in_sec=0} {print}
    ' "$BEFORE_RULES_FILE" > "$tmp" && mv "$tmp" "$BEFORE_RULES_FILE"
}
safe_add_source_quench() {
    local rule="-A ufw-before-input -p icmp --icmp-type source-quench -j DROP"
    grep -qF -- "$rule" "$BEFORE_RULES_FILE" && return 0
    for hdr in "# ok icmp codes for INPUT" "# ok icmp code for INPUT"; do
        if grep -q "^$hdr" "$BEFORE_RULES_FILE"; then
            awk -v r="$rule" -v h="$hdr" '
                $0~"^"h{print;r_added=0;next}
                !r_added&&/^[^#]/&&!/source-quench/{print r;r_added=1}{print}
            ' "$BEFORE_RULES_FILE" > "${BEFORE_RULES_FILE}.tmp" &&
            mv "${BEFORE_RULES_FILE}.tmp" "$BEFORE_RULES_FILE" && break
        fi
    done
}
safe_replace_accept_in_section "# ok icmp codes for INPUT"
safe_replace_accept_in_section "# ok icmp code for INPUT"
safe_replace_accept_in_section "# ok icmp codes for FORWARD"
safe_replace_accept_in_section "# ok icmp code for FORWARD"
safe_add_source_quench
ufw reload >/dev/null 2>&1
log_success "ICMP заблокирован."

# ===================================================================================
# === ШАГ 11: VLESS + REALITY INBOUND (ИСПРАВЛЕННАЯ ВЕРСИЯ) =========================
# ===================================================================================

log "⚡ Шаг 11: Настройка VLESS+Reality inbound..."

# --- Проверка порта 443 ---
if ss -tuln 2>/dev/null | grep -q ":$REALITY_PORT "; then
    log_error "Порт $REALITY_PORT занят. Остановите мешающие сервисы:"
    ss -tulnp 2>/dev/null | grep ":$REALITY_PORT "
    exit 1
fi

# --- Защита от конфликта панели и Reality ---
PANEL_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key = 'webPort';")
if [[ "$PANEL_PORT" == "$REALITY_PORT" ]]; then
    NEW_PORT="2053"
    log_warn "Панель использует порт $REALITY_PORT → меняем на $NEW_PORT"
    sqlite3 "$DB_PATH" "UPDATE settings SET value = '$NEW_PORT' WHERE key = 'webPort';"
fi

# --- Генерация ключей Reality ---
log "🔑 Генерация Reality ключей..."
[[ ! -x "$XRAY_BIN" ]] && XRAY_BIN=$(find /usr/local/x-ui -name xray -type f | head -n1)
[[ ! -x "$XRAY_BIN" ]] && { log_error "Xray не найден."; exit 1; }

REALITY_KEYS=$("$XRAY_BIN" x25519 2>/dev/null)
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | cut -d' ' -f3)
REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | cut -d' ' -f3)

[[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]] && {
    log_error "Не удалось сгенерировать ключи. Проверьте: $XRAY_BIN x25519"
    exit 1
}
log "Reality ключи: OK"

# --- Генерация shortIds (5 штук) ---
SHORTIDS=(); for i in {1..5}; do SHORTIDS+=("$(generate_short_id)"); done

# --- Генерация 3 клиентов ---
CLIENTS=()
for i in {1..3}; do
    UUID=$(uuidgen); EMAIL="client_$i@auto"; SUBID=$(generate_sub_id); TS=$(($(date +%s)000))
    CLIENTS+=("$UUID|$EMAIL|$SUBID|$TS")
done

# --- Формирование JSON ---
SETTINGS_JSON='{"clients":['
for idx in "${!CLIENTS[@]}"; do
    IFS='|' read -r UUID EMAIL SUBID TS <<< "${CLIENTS[$idx]}"
    [[ $idx -gt 0 ]] && SETTINGS_JSON+=","
    SETTINGS_JSON+="{\"comment\":\"\",\"created_at\":$TS,\"email\":\"$EMAIL\",\"enable\":true,\"expiryTime\":0,\"flow\":\"xtls-rprx-vision\",\"id\":\"$UUID\",\"limitIp\":0,\"reset\":0,\"subId\":\"$SUBID\",\"tgId\":0,\"totalGB\":0,\"updated_at\":$TS}"
done
SETTINGS_JSON+='],"decryption":"none","encryption":"none"}'

STREAM_JSON=$(printf '%s' \
'{"network":"tcp","security":"reality","externalProxy":[],"realitySettings":{"show":false,"xver":0,"target":"'"$REALITY_TARGET"'","serverNames":['"$(printf '"%s",' "${REALITY_SERVERNAMES[@]}" | sed 's/,$//')"'],"privateKey":"'"$REALITY_PRIVATE_KEY"'","minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":['"$(printf '"%s",' "${SHORTIDS[@]}" | sed 's/,$//')"'],"mldsa65Seed":"","settings":{"publicKey":"'"$REALITY_PUBLIC_KEY"'","fingerprint":"'"$REALITY_FINGERPRINT"'","serverName":"","spiderX":"'"$REALITY_SPIDERX"'","mldsa65Verify":""}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')

# --- Бэкап БД ---
BACKUP_DB="$DB_PATH.bak_$(date +%s)"
cp "$DB_PATH" "$BACKUP_DB" && log "💾 Бэкап БД: $BACKUP_DB"

# --- Удаление старых inbound'ов ---
sqlite3 "$DB_PATH" "DELETE FROM inbounds WHERE port = $REALITY_PORT;" 2>/dev/null

# --- Вставка нового inbound ---
log "📥 Вставка inbound в БД..."
sqlite3 "$DB_PATH" <<EOF
INSERT INTO inbounds (
    user_id, up, down, total, remark, enable, expiry_time,
    traffic_reset, last_traffic_reset_time, listen, port, protocol,
    settings, stream_settings, tag, sniffing
) VALUES (
    0, 0, 0, 0, 'AutoReality', 1, 0,
    'never', 0, '', $REALITY_PORT, 'vless',
    '$(echo "$SETTINGS_JSON" | sed "s/'/''/g")',
    '$(echo "$STREAM_JSON" | sed "s/'/''/g")',
    'inbound-$REALITY_PORT',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);
EOF

if [[ $? -ne 0 ]]; then
    log_error "Ошибка вставки inbound. Восстановление из бэкапа."
    cp "$BACKUP_DB" "$DB_PATH"
    exit 1
fi
log_success "Inbound добавлен."

# --- Перезапуск и проверка ---
systemctl restart x-ui; sleep 5
if journalctl -u x-ui -n 30 --no-pager 2>/dev/null | grep -q "started.*:$REALITY_PORT"; then
    log_success "✅ Reality inbound активен на порту $REALITY_PORT"
else
    log_warn "Inbound не подтверждён в логах. Проверьте: journalctl -u x-ui"
fi

# --- Генерация ссылок ---
echo; log "🔗 ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ:"
SERVER_IP=$(hostname -I | awk '{print $1}'); [[ -z "$SERVER_IP" ]] && SERVER_IP="YOUR_SERVER_IP"

for idx in "${!CLIENTS[@]}"; do
    IFS='|' read -r UUID EMAIL _ _ <<< "${CLIENTS[$idx]}"
    SID=${SHORTIDS[$idx]}
    LINK="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&security=reality&fp=$REALITY_FINGERPRINT&sni=${REALITY_SERVERNAMES[0]}&pbk=$REALITY_PUBLIC_KEY&sid=$SID&type=tcp&flow=xtls-rprx-vision#$EMAIL"
    echo "🔹 $EMAIL:"
    echo "   $LINK"
    echo
done

# ===================================================================================
# === ШАГ 12: ИТОГИ =================================================================
# ===================================================================================

PANEL_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key = 'webPort';")
PANEL_URL="https://$SERVER_IP:$PANEL_PORT$(echo "/$EXTRACTED_WEBBASEPATH" | sed 's|//*|/|g')"
SERVICE_STATUS=$(systemctl is-active x-ui 2>/dev/null)

echo "========================================"
log_success "✅ УСТАНОВКА ЗАВЕРШЕНА (v6.1)"
echo
log "📍 Панель: $PANEL_URL"
echo "   Логин: $EXTRACTED_USERNAME"
echo "   Пароль: $EXTRACTED_PASSWORD"
log "⚙️  Служба: $SERVICE_STATUS"
log "🌐 Reality: VLESS+TCP+Reality (порт $REALITY_PORT, target=$REALITY_TARGET)"
log "👥 Клиенты: 3 (см. ссылки выше)"
echo
log "📌 Советы:"
echo "  • В браузере при заходе в панель нажмите «Дополнительно → Перейти» (самоподписанный SSL)"
echo "  • Скопируйте любую ссылку в клиент (V2RayN, Qv2ray, Sing-box)"
echo "  • Для смены target/SNI — отредактируйте inbound в панели"
echo "========================================"
exit 0
